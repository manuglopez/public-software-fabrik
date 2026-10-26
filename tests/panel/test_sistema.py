"""AC-3e Cupos y AC-3f Máquina: `GET /cupos` y `GET /maquina` (dashboard/fx_sistema.py).

Sin HOME real: FABRIK_DATA es un directorio temporal, `/proc` es un árbol simulado y la config se sustituye.
"""
import datetime as dt
import fcntl
import json
import os
import shutil
import sys
import tempfile
from pathlib import Path
from unittest import mock

from tests.panel.base import PanelTest

T = 1792800000.0  # instante de la foto del fixture


def iso(s: str) -> dt.datetime:
    return dt.datetime.fromisoformat(s.replace("Z", "+00:00"))


class SistemaTest(PanelTest):
    def setUp(self):
        super().setUp()
        self.fx = sys.modules["fabrica_fx_sistema"]
        self.comun = sys.modules["fabrica_comun"]
        self.tmp = Path(tempfile.mkdtemp(prefix="fx-sistema-"))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        entorno = mock.patch.dict(os.environ, {"FABRIK_DATA": str(self.tmp / "data")})
        entorno.start()
        self.addCleanup(entorno.stop)
        os.environ.pop("FABRIK_CUPOS_LOG", None)
        self.cfg = {}
        for parche in (
            mock.patch.object(self.comun, "config", side_effect=lambda: self.cfg),
            mock.patch.object(self.fx, "ahora", return_value=T + 60),
        ):
            parche.start()
            self.addCleanup(parche.stop)

    def escribir_foto(self, *fotos):
        log = self.tmp / "data" / "logs" / "cupos.jsonl"
        log.parent.mkdir(parents=True, exist_ok=True)
        log.write_text("".join(json.dumps(f) + "\n" for f in fotos), encoding="utf-8")
        return log


class TestCupos(SistemaTest):
    def test_ultima_foto_con_bolsas_en_orden_porcentaje_y_renovacion_local(self):
        vieja = {**self.fixture("sistema_cupos_foto"), "t": T - 600, "bolsas": {"kimi_5h": [1, "2026-10-24T06:27:10Z"]}}
        self.escribir_foto(vieja, self.fixture("sistema_cupos_foto"))
        r = self.client.get("/cupos").json()
        self.assertEqual([b["bolsa"] for b in r["bolsas"]],
                         ["claude_5h@uno", "claude_sem@uno", "claude_sem@dos", "kimi_5h", "kimi_7d", "gemini_sem"])
        self.assertEqual([b["usado"] for b in r["bolsas"]], [9.0, 84.4, 6.0, 100.0, 75.0, 0.0])
        self.assertEqual(iso(r["foto"]), dt.datetime.fromtimestamp(T, dt.UTC))
        self.assertIsNotNone(iso(r["foto"]).utcoffset(), "la hora va con offset local")
        self.assertEqual(iso(r["bolsas"][0]["renueva"]), dt.datetime(2026, 10, 24, 5, tzinfo=dt.UTC))
        self.assertEqual(iso(r["bolsas"][2]["renueva"]), dt.datetime(2026, 10, 27, 10, tzinfo=dt.UTC))

    def test_aviso_por_defecto_solo_para_la_semanal_de_claude_por_encima_del_75(self):
        self.escribir_foto(self.fixture("sistema_cupos_foto"))
        avisos = self.client.get("/cupos").json()["avisos"]
        self.assertEqual(len(avisos), 1, avisos)  # kimi_5h al 100 % no está vigilada; claude_sem@dos está al 6 %
        self.assertRegex(avisos[0], r"^Cupo claude_sem@uno al 84 % \(renueva 2026-10-2\d \d\d:00\)$")

    def test_cupos_aviso_de_la_config_cambia_la_bolsa_vigilada(self):
        self.escribir_foto(self.fixture("sistema_cupos_foto"))
        self.cfg = {"cupos": {"aviso": "kimi_5h"}}
        self.assertEqual([a.split(" (")[0] for a in self.client.get("/cupos").json()["avisos"]], ["Cupo kimi_5h al 100 %"])
        self.cfg = {"cupos": {"aviso": ["kimi_7d", "gemini_sem"]}}
        self.assertEqual(self.client.get("/cupos").json()["avisos"], [], "75 % y 0 % no pasan del 75 %")

    def test_justo_en_el_umbral_no_avisa(self):
        self.escribir_foto({"t": T, "bolsas": {"claude_sem": [75, "2026-10-25T16:00:00Z"], "claude_sem@x": [75.1, None]}, "errores": {}})
        self.assertEqual(self.client.get("/cupos").json()["avisos"], ["Cupo claude_sem@x al 75 %"])

    def test_foto_vieja_y_errores_de_la_foto_se_avisan(self):
        self.escribir_foto({**self.fixture("sistema_cupos_foto"), "errores": {"gemini": "HTTP 401"}})
        self.fx.ahora.return_value = T + 3600
        avisos = self.client.get("/cupos").json()["avisos"]
        self.assertIn("La foto de cupos tiene 60 min: ¿está parado fabrica-cupos.timer?", avisos)
        self.assertIn("Sin datos de gemini: HTTP 401", avisos)

    def test_fabrik_cupos_log_manda_sobre_fabrik_data(self):
        otro = self.tmp / "otro.jsonl"
        otro.write_text(json.dumps({"t": T, "bolsas": {"kimi_5h": [3, "2026-10-24T06:27:10Z"]}}) + "\n", encoding="utf-8")
        with mock.patch.dict(os.environ, {"FABRIK_CUPOS_LOG": str(otro)}):
            self.assertEqual([b["bolsa"] for b in self.client.get("/cupos").json()["bolsas"]], ["kimi_5h"])

    def test_sin_foto_o_foto_rota_no_disponible(self):
        r = self.client.get("/cupos")
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.json()["disponible"], False)
        self.assertIn("no existe", r.json()["motivo"])
        log = self.escribir_foto()
        log.write_text("{no json\n", encoding="utf-8")
        self.assertEqual(self.client.get("/cupos").json(), {"disponible": False, "motivo": "sin foto de cupos: JSON inválido"})


class TestMaquina(SistemaTest):
    def setUp(self):
        super().setUp()
        self.proc = self.tmp / "proc"
        self.proc.mkdir()
        (self.proc / "meminfo").write_text("MemTotal:       32505856 kB\nMemFree:  1 kB\nMemAvailable:   11534336 kB\n")
        (self.proc / "loadavg").write_text("6.25 5.10 4.00 3/1200 4242\n")
        (self.proc / "self").mkdir()
        for parche in (mock.patch.object(self.fx, "PROC", self.proc), mock.patch.object(self.fx.os, "cpu_count", return_value=16)):
            parche.start()
            self.addCleanup(parche.stop)
        self.locks = self.tmp / "data" / "locks"
        self.locks.mkdir(parents=True)

    def proceso(self, pid, argv, ppid=1, cwd="/x/the-factory-sistema", nombre="bash"):
        d = self.proc / str(pid)
        d.mkdir()
        (d / "cmdline").write_bytes(b"\0".join(a.encode() for a in argv) + b"\0")
        (d / "stat").write_text(f"{pid} ({nombre}) S {ppid} 1 1 0 -1\n")
        os.symlink(cwd, d / "cwd")

    def coger_turno(self, owner):
        (self.locks / "factory-test.owner").write_text(owner + "\n")
        f = open(self.locks / "factory-test.lock", "w")
        fcntl.flock(f, fcntl.LOCK_EX)
        self.addCleanup(f.close)

    def test_ram_y_cpu_de_proc(self):
        r = self.client.get("/maquina").json()
        self.assertEqual(r["ram"], {"usado_gb": 20.0, "total_gb": 31.0})
        self.assertEqual(r["cpu"], {"carga": 6.25, "nucleos": 16})

    def test_turno_libre_sin_cola(self):
        (self.locks / "factory-test.owner").write_text("programador pid=1 repo=r cmd=x desde=10:00:00\n")  # titular viejo
        (self.locks / "factory-test.lock").touch()
        self.assertEqual(self.client.get("/maquina").json()["suite"], {"titular": None, "cola": []})

    def test_titular_con_turno_cogido_y_cola_con_prioridad_sin_subshells_ni_estado(self):
        self.coger_turno("programador pid=100 repo=software-fabrik [IMPL-4] cmd=bash tests/panel_backend_test.sh desde=18:31:02")
        self.proceso(100, ["bash", "/usr/local/bin/factory-test", "--etiqueta", "IMPL-4", "--", "bash", "tests/panel_backend_test.sh"])
        self.proceso(101, ["bash", "/usr/local/bin/factory-test", "--", "bash", "t.sh"], ppid=100)  # subshell del titular
        self.proceso(200, ["/usr/bin/bash", "/opt/fabrik/bin/factory-test", "--", "vendor/bin/phpunit"], cwd="/w/api-acme")
        self.proceso(201, ["bash", "/opt/fabrik/bin/factory-test", "--", "vendor/bin/phpunit"], ppid=200, cwd="/w/api-acme")
        self.proceso(300, ["bash", "factory-test", "npm", "test"], cwd="/w/web")
        self.proceso(400, ["bash", "/opt/fabrik/bin/factory-test", "estado"])
        self.proceso(500, ["vim", "factory-test.md"], nombre="vim")
        (self.locks / "prio.d").mkdir()
        (self.locks / "prio.d" / "300").write_text("inicio=1\nprogramador pid=300 repo=web-raiz cmd=npm test desde=18:32:00\n")
        (self.locks / "prio.d" / "999").write_text("inicio=1\nde un pid muerto\n")
        suite = self.client.get("/maquina").json()["suite"]
        self.assertEqual(suite["titular"], {
            "texto": "programador pid=100 repo=software-fabrik [IMPL-4] cmd=bash tests/panel_backend_test.sh desde=18:31:02",
            "quien": "programador", "pid": "100", "repo": "software-fabrik", "etiqueta": "IMPL-4",
            "cmd": "bash tests/panel_backend_test.sh", "desde": "18:31:02"})
        self.assertEqual(suite["cola"], [
            {"pid": 300, "repo": "web-raiz", "cmd": "npm test", "prioridad": True},
            {"pid": 200, "repo": "api-acme", "cmd": "vendor/bin/phpunit", "prioridad": False},
        ])

    def test_repo_de_la_cola_es_la_raiz_git_del_cwd(self):
        raiz = self.tmp / "repos" / "mi-repo"
        (raiz / ".git").mkdir(parents=True)
        (raiz / "sub" / "dir").mkdir(parents=True)
        self.proceso(700, ["bash", "/opt/fabrik/bin/factory-test", "--", "make", "test"], cwd=str(raiz / "sub" / "dir"))
        self.assertEqual(self.client.get("/maquina").json()["suite"]["cola"],
                         [{"pid": 700, "repo": "mi-repo", "cmd": "make test", "prioridad": False}])

    def test_owner_con_formato_desconocido_se_muestra_tal_cual(self):
        self.coger_turno("alguien a mano")
        self.assertEqual(self.client.get("/maquina").json()["suite"]["titular"], {"texto": "alguien a mano"})

    def test_sin_proc_cada_bloque_dice_no_disponible_y_el_resto_sigue(self):
        (self.proc / "meminfo").unlink()
        (self.proc / "loadavg").write_text("")
        r = self.client.get("/maquina")
        self.assertEqual(r.status_code, 200)
        self.assertFalse(r.json()["ram"]["disponible"])
        self.assertFalse(r.json()["cpu"]["disponible"])
        self.assertEqual(r.json()["suite"], {"titular": None, "cola": []})


class TestRegistro(PanelTest):
    def test_rutas_registradas(self):
        rutas = {r.path for r in self.api.router.routes}
        self.assertLessEqual({"/cupos", "/maquina"}, rutas)


if __name__ == "__main__":
    import unittest

    unittest.main()
