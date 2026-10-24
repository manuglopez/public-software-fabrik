#!/usr/bin/env python3
"""Helper de tests para tests/triage_cupo_test.sh.

Se ejecuta con el Python del venv de Hermes (PYTHONPATH=hermes-agent) y un
HOME temporal, y aplica cambios reales sobre el tablero temporal de pruebas:

  crear <json>            → crea tarjetas (assignee/override/título) y las deja en ready
  schedule <board> <id>   → schedule_task (efecto del `hermes kanban schedule` real)
  unblock <board> <id>    → unblock_task
  comentario <board> <id> <autor> <body> → inserta un comentario
  estado <board>          → imprime «id:status» de cada tarjeta
"""
import json
import os
import sys

from hermes_cli.kanban_db_connect import connect
from hermes_cli.kanban_db import create_task, schedule_task, unblock_task
from hermes_cli.kanban_db_boards import create_board


def main() -> int:
    modo = sys.argv[1]
    if modo == "init":
        create_board("pruebas", name="Tablero de pruebas cupo")
        return 0
    if modo == "crear":
        specs = json.loads(sys.argv[2])
        c = connect(board="pruebas")
        ids = []
        for s in specs:
            tid = create_task(
                c, title=s["title"], assignee=s.get("assignee"),
                model_override=s.get("model_override"),
                provider_override=s.get("provider_override"),
                initial_status="running", board="pruebas",
            )
            # Las tarjetas del test se quieren «ready» ya promocionadas
            c.execute("update tasks set status='ready' where id=?", (tid,))
            c.commit()
            ids.append(tid)
        for tid in ids:
            print(tid)
        return 0
    if modo == "schedule":
        c = connect(board=sys.argv[2])
        ok = schedule_task(c, sys.argv[3], reason="aparcada por cupo (test)")
        print("ok" if ok else "fallo")
        return 0 if ok else 1
    if modo == "unblock":
        c = connect(board=sys.argv[2])
        ok = unblock_task(c, sys.argv[3])
        print("ok" if ok else "fallo")
        return 0 if ok else 1
    if modo == "comentario":
        import time
        c = connect(board=sys.argv[2])
        c.execute(
            "insert into task_comments (task_id, author, body, created_at) values (?,?,?,?)",
            (sys.argv[3], sys.argv[4], sys.argv[5], int(time.time())),
        )
        c.commit()
        return 0
    if modo == "estado":
        c = connect(board=sys.argv[2])
        for tid, status in c.execute("select id, status from tasks order by id"):
            print(f"{tid}:{status}")
        return 0
    print(f"modo desconocido: {modo}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
