#!/usr/bin/env python3
"""Configura los perfiles de la fábrica de forma idempotente: modelo + reserva, toolsets, comandos prohibidos
(approvals.deny), compactación por rol, entorno de shell y SOUL.md (profiles/<rol>.md + profiles/_comun.md).

Uso: uv run --with pyyaml python apply_profile_policy.py [--seco|--solo-soul] [rol ...]
Los modelos se pueden cambiar aquí o luego desde el panel / `hermes -p <rol> config set model.*`.
--seco imprime los modelos por rol (de la config) sin tocar hermes ni ficheros.
Crea el perfil si no existe (`hermes profile create <rol> --clone --no-alias`).
"""
import json
import re
import subprocess
import sys
from pathlib import Path

import fabrik_config

REPO = Path(__file__).resolve().parent.parent
# Cuándo usar cada nivel del pool: texto fijo del motor (el pack solo aporta los modelos).
CUANDO_NIVEL = {
    "ligero": "leer, resumir, docs, triage, pocas herramientas",
    "medio": "tests, IMPL S acotada, scripts, terminal intensiva",
    "dificil": "IMPL con razonamiento, integrar ramas, conflictos, CIERRE-LOCAL, tallas M/L",
    "critico": "PLAN, revisión, tenancy/RBAC/migraciones/pagos",
}


def cadena_fallback(principal, reservas, final):
    """Reservas del rol + reserva final al final. Si la final ya estaba en la cadena se quita de donde
    esté y queda solo al final; si coincide con el modelo principal del rol, no se añade."""
    if not final:
        return list(reservas)
    if tuple(final) == tuple(principal):
        return [r for r in reservas if tuple(r) != tuple(final)]
    return [r for r in reservas if tuple(r) != tuple(final)] + [tuple(final)]


def roles_desde_config(config=None):
    """ROLES desde `modelos` de la config: rol -> ((proveedor, modelo), [(res_prov, res_modelo), ...], compacta).
    Los roles salen de `fabrik_config.roles()` (pool, reserva_final y permitir_pago no son roles); la
    reserva final de `modelos.reserva_final` va siempre al final de la cadena de cada rol."""
    if config is None:
        config = fabrik_config.cargar()
    rf = fabrik_config.reserva_final(config)
    final = (rf["proveedor"], rf["modelo"]) if rf and rf.get("proveedor") and rf.get("modelo") else None
    roles = {}
    for rol, m in fabrik_config.roles(config).items():
        prov = m.get("proveedor") or ""
        model = m.get("modelo") or ""
        normalizadas = fabrik_config.normalizar_reserva(m.get("reserva"), prov)
        reservas = [(r["proveedor"], r["modelo"]) for r in normalizadas if r.get("proveedor") and r.get("modelo")]
        roles[rol] = ((prov, model), cadena_fallback((prov, model), reservas, final), m.get("compacta", 160_000))
    return roles


ROLES = roles_desde_config()
WORKER = ["terminal", "file", "todo", "skills", "memory", "session_search", "code_execution"]
TOOLSETS = {r: WORKER for r in ROLES}
# El orquestador necesita terminal para gh (trabajo vivo del usuario) y fabrik-memoria; su SOUL le prohíbe implementar.
TOOLSETS["orquestador"] = ["kanban", "terminal", "file", "todo", "skills", "memory", "session_search"]
SKILL_CATS_KEEP = {"autonomous-ai-agents", "devops", "software-development"}

PROTECTED = ["develop", "main", "master"]
DENY = [
    # merge y privilegios de admin: sólo el humano
    "*gh pr merge*", "*--admin*", "*gh api*/merge*", "*gh api*merges*",
    "*gh api*-X DELETE*", "*gh api*--method DELETE*", "*gh api*protection*", "*gh api*rulesets*",
    "*gh repo delete*", "*gh repo edit*", "*gh repo archive*", "*gh release*", "*gh secret*", "*gh variable*",
    # push: nada a ramas protegidas, nada de --force (sí --force-with-lease en su rama), nada de borrar ramas
    "*git push*--force", "*git push*--force *", "*git push* -f", "*git push* -f *",
    "*git push*--delete*", "*git push* :*", "*git push*--mirror*", "*git push*--all*",
    *[f"*git push* {b}" for b in PROTECTED], *[f"*git push* {b} *" for b in PROTECTED],
    *[f"*git push*:{b}" for b in PROTECTED], *[f"*git push*:{b} *" for b in PROTECTED],
    "*git push* release/*", "*git push*:release/*",
    # producción y servidores: sólo el usuario (constitución G7)
    "ssh *", "* ssh *", "*;ssh *", "*&&ssh *", "*scp *", "*sftp *", "*rsync *:*",
    # ni siquiera mirar la configuración/llaves SSH del usuario (lista de servidores de producción)
    "*.ssh/*", "*~/.ssh*", "*/.ssh *", "*ssh-add*", "*ssh-agent*",
    "*dep deploy*", "*vendor/bin/dep *", "*envoy run*", "*--env=production*", "*--env=prod *",
    # bases de datos del usuario
    "*-uroot*", "*-u root*", "*--user=root*", "*drop database*",
    # tests SOLO vía factory-test (carga la BD de la fábrica y da el turno); sin él irían a la BD del usuario
    *[f"{pre}{cmd}*" for pre in ("", "*&& ", "*; ", "*&&", "*;")
      for cmd in ("php artisan test", "vendor/bin/phpunit", "./vendor/bin/phpunit", "php vendor/bin/phpunit",
                  "vendor/bin/paratest", "php vendor/bin/paratest", "composer test", "npm test", "npm run test")],
]


def sh(*a):
    return subprocess.run(a, capture_output=True, text=True)


def cset(prof, key, val):
    v = val if isinstance(val, str) else json.dumps(val)
    r = sh("hermes", "-p", prof, "config", "set", key, v)
    if r.returncode:
        raise RuntimeError(f"{prof} {key}: {r.stderr.strip()[:200]}")


def _modelo_md(entrada):
    sufijo = "" if entrada.get("herramientas") is not False else " (sin herramientas)"
    return f"`{entrada['modelo']}` (`{entrada['proveedor']}`){sufijo}"


def texto_reserva_final(config):
    """`modelo` (`proveedor`) de la reserva final, o «ninguna»."""
    rf = fabrik_config.reserva_final(config)
    if not rf or not rf.get("modelo") or not rf.get("proveedor"):
        return "ninguna"
    return f"`{rf['modelo']}` (`{rf['proveedor']}`)"


def tabla_pool(config):
    """Tabla Markdown del pool efectivo (solo niveles con entradas) y, debajo, la línea de los de pago
    excluidos. Con el pool vacío: «Sin pool configurado: usa el modelo del perfil.»"""
    pool, excluidos = fabrik_config.pool_efectivo(config)
    if not pool:
        return "Sin pool configurado: usa el modelo del perfil."
    lineas = ["| Nivel | Cuándo | Modelos (proveedor) |", "| --- | --- | --- |"]
    for nivel, entradas in pool.items():
        lineas.append(f"| {nivel} | {CUANDO_NIVEL[nivel]} | " + " · ".join(_modelo_md(e) for e in entradas) + " |")
    if excluidos:
        lineas += ["", "De pago, solo si el humano lo pide: "
                   + " · ".join(f"`{e['modelo']}` (`{e['proveedor']}`)" for e in excluidos)]
    return "\n".join(lineas)


def obtener_valores_plantilla(config):
    titulo = config.get("titulo") or "la fábrica"
    owners = config.get("owners") or []
    owners_str = ", ".join(str(o) for o in owners) if isinstance(owners, list) else str(owners)
    repos = config.get("repos_calientes") or []
    repos_str = ", ".join(str(r) for r in repos) if isinstance(repos, list) else str(repos)
    return {"titulo": titulo, "owners": owners_str, "repos_calientes": repos_str,
            "pool_modelos": tabla_pool(config), "reserva_final": texto_reserva_final(config)}


def sustituir_variables(texto, valores):
    def reemplazar(match):
        var = match.group(1)
        if var not in valores:
            print(f"variable de plantilla desconocida: {var}", file=sys.stderr)
            sys.exit(1)
        return str(valores[var])
    return re.sub(r"\{\{([a-zA-Z0-9_]+)\}\}", reemplazar, texto)


def _leer(ruta):
    """Texto recortado de un fichero, o None si no existe o está vacío."""
    if not ruta.is_file():
        return None
    return ruta.read_text(encoding="utf-8").strip() or None


def soul(rol, config=None):
    """SOUL = profiles/<rol>.md + profiles/<rol>.md de cada pack activo + profiles/_comun.md
    + profiles/_comun.md de cada pack activo; luego sustituye las variables de plantilla."""
    if config is None:
        config = fabrik_config.cargar()
    personal_path = fabrik_config.config_personal_path()
    personal = fabrik_config.cargar_yaml(personal_path)
    dirs_pack = [yp.parent / "profiles" for yp in fabrik_config.packs_activos(personal, personal_path)]
    rutas = [REPO / "profiles" / f"{rol}.md"]
    rutas += [d / f"{rol}.md" for d in dirs_pack]
    rutas += [REPO / "profiles" / "_comun.md"]
    rutas += [d / "_comun.md" for d in dirs_pack]
    partes = [t for t in (_leer(r) for r in rutas) if t]
    return sustituir_variables("\n\n".join(partes) + "\n", obtener_valores_plantilla(config))


def main():
    args = sys.argv[1:]
    seco = "--seco" in args
    solo_soul = "--solo-soul" in args
    roles = [a for a in args if not a.startswith("--")] or list(ROLES)
    config = fabrik_config.cargar()
    if seco:
        if solo_soul:
            for rol in roles:
                if rol not in ROLES:
                    print(f"{rol}: rol desconocido (no está en modelos)", file=sys.stderr)
                    continue
                soul(rol, config)
                print(f"{rol:<12} SOUL.md OK (seco)")
            return
        # Solo lectura: imprime los modelos por rol (de la config) sin llamar a hermes ni tocar ficheros.
        for rol in roles:
            if rol not in ROLES:
                print(f"{rol}: rol desconocido (no está en modelos)", file=sys.stderr)
                continue
            (prov, model), reservas, ctok = ROLES[rol]
            cadena_reserva = (" → reserva " + " → ".join(f"{p}/{m}" for p, m in reservas)) if reservas else " → sin reserva"
            print(f"{rol:<12} {prov}/{model}{cadena_reserva} · compacta {ctok//1000}k")
        return
    home = Path.home() / ".hermes/profiles"
    for rol in roles:
        (prov, model), reservas, ctok = ROLES[rol]
        pdir = home / rol
        if not pdir.exists():
            r = sh("hermes", "profile", "create", rol, "--clone", "--no-alias")
            if r.returncode:
                print(f"{rol}: ERROR creando perfil {r.stderr[:200]}"); continue
        pdir.mkdir(parents=True, exist_ok=True)
        (pdir / "SOUL.md").write_text(soul(rol, config), encoding="utf-8")
        if solo_soul:
            print(f"{rol:<12} SOUL.md OK"); continue
        cset(rol, "model.provider", prov); cset(rol, "model.default", model); cset(rol, "model.base_url", "")
        fallback_providers = [{"provider": p, "model": m} for p, m in reservas]
        cset(rol, "fallback_providers", fallback_providers)
        cset(rol, "platform_toolsets.cli", TOOLSETS[rol])
        cset(rol, "approvals.deny", DENY)
        cset(rol, "compression.threshold", "0.5"); cset(rol, "compression.threshold_tokens", str(ctok))
        cset(rol, "compression.proactive_prune_tokens", "80000"); cset(rol, "compression.micro_compact", "true")
        cset(rol, "terminal.shell_init_files", [str(REPO / "config/agent-shell.sh")])
        cset(rol, "terminal.timeout", "600")
        # pasos por tarjeta: 150 se quedaba corto en IMPL con TDD real (dos tarjetas reales se rindieron en 150/150)
        cset(rol, "agent.max_turns", {"programador": "250", "tester": "200"}.get(rol, "150"))
        envf = pdir / ".env"; env = envf.read_text() if envf.exists() else ""
        if "GH_CONFIG_DIR=" not in env:
            envf.write_text(env.rstrip("\n") + f"\nGH_CONFIG_DIR={Path.home()}/.config/gh\n")
        sk = pdir / "skills"
        if sk.exists():
            for c in sk.iterdir():
                if c.is_dir() and c.name not in SKILL_CATS_KEEP:
                    subprocess.run(["rm", "-rf", str(c)])
        sh("hermes", "-p", rol, "plugins", "disable", "hermes-seo")
        cadena_reserva = (" → reserva " + " → ".join(f"{p}/{m}" for p, m in reservas)) if reservas else " → sin reserva"
        print(f"{rol:<12} {prov}/{model}{cadena_reserva} · compacta {ctok//1000}k · deny {len(DENY)} · SOUL OK", flush=True)


if __name__ == "__main__":
    main()
