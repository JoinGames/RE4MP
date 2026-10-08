#!/usr/bin/env python3
"""
RE4 LAN Co-op v0.2.1 — ретранслятор (relay). Только стандартная библиотека Python 3.8+.

Зачем он нужен: в Lua-скриптах REFramework нет сокетов, поэтому мод (RE4LAN.lua) обменивается
с этой программой через небольшие JSON-файлы в  <игра>/reframework/data/ , а программа
передаёт данные другому игроку по UDP в локальной сети.

Запуск (у ОДНОГО игрока — host, у другого — join):

    python re4lan_relay.py host --data "D:\\Games\\RE4\\reframework\\data"
    python re4lan_relay.py join 192.168.1.23 --data "D:\\Games\\RE4\\reframework\\data"

  host  — ждёт подключения (порт по умолчанию 7777; при первом запуске Windows спросит про
          брандмауэр — разреши доступ для частной сети);
  join  — подключается к IP хоста (узнать его: команда  ipconfig  -> "IPv4-адрес");
  echo  — тест в одиночку: ретранслятор сам "отвечает" твоим же состоянием, сдвинутым на 3 м,
          чтобы проверить, что мод видит "второго игрока".

Запускать ДО или ПОСЛЕ старта игры — не важно. Остановка: Ctrl+C.
"""
import argparse
import json
import os
import socket
import sys
import time

MAGIC = b"RE4L"
PROTO = 1
VERSION = "0.2.1"

F_OUT = "RE4LAN_out.json"        # Lua -> relay
F_IN = "RE4LAN_in.json"          # relay -> Lua (состояние второго игрока)
F_STATUS = "RE4LAN_status.json"  # relay -> Lua (состояние связи)


def read_json(path):
    """Читает JSON; при гонке с записью Lua (файл недописан) возвращает None."""
    try:
        with open(path, "r", encoding="utf-8") as f:
            text = f.read()
        if not text.strip():
            return None
        return json.loads(text)
    except (OSError, ValueError):
        return None


def atomic_write(path, obj):
    """Пишет во временный файл и атомарно подменяет — Lua никогда не увидит половину файла."""
    tmp = path + ".tmp"
    data = json.dumps(obj, ensure_ascii=True, separators=(",", ":"))
    for _ in range(5):
        try:
            with open(tmp, "w", encoding="utf-8") as f:
                f.write(data)
            os.replace(tmp, path)
            return True
        except OSError:
            time.sleep(0.002)  # файл на миг занят (Lua его читает) — пробуем ещё раз
    return False


def pack(obj):
    return MAGIC + json.dumps(obj, ensure_ascii=True, separators=(",", ":")).encode("ascii")


def unpack(data):
    if not data.startswith(MAGIC):
        return None
    try:
        return json.loads(data[len(MAGIC):].decode("ascii"))
    except (ValueError, UnicodeDecodeError):
        return None


class ExchangeRates:
    """File/network observations measured with a local monotonic clock.

    out_hz counts new Lua snapshots read, not successful UDP sends. in_hz counts
    received states (the synthetic echo states in echo mode), not ping packets.
    out_gap_ms includes silence up to the status update; idle keepalives naturally
    produce a larger gap than a continuously moving player.
    """

    def __init__(self, now):
        self.start = now
        self.out_count = self.in_count = 0
        self.last_out = self.last_in = None
        self.max_out_gap = 0.0

    def observe_out(self, now):
        if self.last_out is not None:
            self.max_out_gap = max(self.max_out_gap, now - self.last_out)
        self.last_out = now
        self.out_count += 1

    def observe_in(self, now):
        self.last_in = now
        self.in_count += 1

    def snapshot(self, now):
        dt = max(now - self.start, 1e-9)
        gap = self.max_out_gap
        if self.last_out is not None:
            gap = max(gap, now - self.last_out)
        result = {
            "out_hz": round(self.out_count / dt, 1),
            "in_hz": round(self.in_count / dt, 1),
            "out_gap_ms": round(gap * 1000, 1),
            "in_age_ms": round((now - self.last_in) * 1000, 1) if self.last_in is not None else -1,
        }
        self.start = now
        self.out_count = self.in_count = 0
        self.max_out_gap = 0.0
        return result


def main():
    ap = argparse.ArgumentParser(description="RE4 LAN Co-op relay")
    ap.add_argument("mode", choices=["host", "join", "echo"])
    ap.add_argument("address", nargs="?", help="IP хоста (для join)")
    ap.add_argument("--port", type=int, default=7777)
    ap.add_argument("--data", default=".", help="папка <игра>/reframework/data")
    args = ap.parse_args()

    if not 1 <= args.port <= 65535:
        ap.error("--port должен быть в диапазоне 1..65535")
    if args.mode == "join" and not args.address:
        ap.error("для join укажи IP хоста: python re4lan_relay.py join 192.168.1.23 --data ...")
    if not os.path.isdir(args.data):
        # папки data может ещё не быть, если ни один скрипт REFramework в неё не писал —
        # создаём, но только если рядом есть сам REFramework (папка reframework)
        parent = os.path.dirname(os.path.normpath(args.data))
        if os.path.isdir(parent) and os.path.basename(parent).lower() == "reframework":
            os.makedirs(args.data, exist_ok=True)
            print("Создана папка данных: %s" % args.data)
        else:
            sys.exit("Папка --data не найдена: %s\n"
                     "Проверь путь к игре. Папка reframework должна существовать "
                     "(там, где лежит dinput8.dll)." % args.data)

    p_out = os.path.join(args.data, F_OUT)
    p_in = os.path.join(args.data, F_IN)
    p_status = os.path.join(args.data, F_STATUS)

    sock = None
    peer = None
    if args.mode != "echo":
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.setblocking(False)
        if args.mode == "host":
            sock.bind(("0.0.0.0", args.port))
            print("[host] слушаю порт %d. Дай второму игроку свой IP (ipconfig)." % args.port)
        else:
            sock.bind(("0.0.0.0", 0))
            peer = (args.address, args.port)
            print("[join] подключаюсь к %s:%d ..." % peer)

    in_seq = int(time.time())          # растёт монотонно, меняется между перезапусками
    last_out_seq = None
    last_rx = 0.0
    last_hello = 0.0
    last_ping = 0.0
    last_status = time.monotonic()
    rates = ExchangeRates(last_status)
    ping_ms = None
    tx = rx = 0
    wfail = 0
    was_connected = False

    print("Папка данных: %s" % os.path.abspath(args.data))
    print("Ctrl+C — выход.")

    try:
        while True:
            now = time.monotonic()

            # ---- 1. Забираем состояние от Lua-мода и отправляем ----
            # (не полагаемся на время изменения файла: в Windows оно обновляется с запаздыванием)
            obj = read_json(p_out)
            if isinstance(obj, dict) and isinstance(obj.get("seq"), (int, float)):
                seq = obj["seq"]
                if seq != last_out_seq:
                    last_out_seq = seq
                    rates.observe_out(now)
                    if args.mode == "echo":
                        fake = json.loads(json.dumps(obj))
                        fake["name"] = "Echo"
                        if isinstance(fake.get("pos"), list) and len(fake["pos"]) == 3:
                            fake["pos"][0] += 3.0
                        in_seq += 1
                        if not atomic_write(p_in, {"seq": in_seq, "d": fake}):
                            wfail += 1
                        last_rx = now
                        rates.observe_in(now)
                    elif peer is not None:
                        try:
                            sock.sendto(pack({"k": "s", "d": obj}), peer)
                            tx += 1
                        except OSError:
                            pass

            # ---- 2. Принимаем пакеты из сети ----
            if sock is not None:
                for _ in range(200):
                    try:
                        data, addr = sock.recvfrom(65535)
                    except (BlockingIOError, ConnectionResetError):
                        break
                    except OSError:
                        break
                    msg = unpack(data)
                    if not isinstance(msg, dict):
                        continue
                    if args.mode == "host" and peer is None:
                        peer = addr
                        print("[host] подключился %s:%d" % addr)
                    if peer is not None and addr != peer and args.mode == "host":
                        continue  # третий игрок — пока не поддерживается
                    last_rx = now
                    k = msg.get("k")
                    if k == "s":
                        d = msg.get("d")
                        if isinstance(d, dict):
                            in_seq += 1
                            if not atomic_write(p_in, {"seq": in_seq, "d": d}):
                                wfail += 1
                            rx += 1
                            rates.observe_in(now)
                    elif k == "p":
                        try:
                            sock.sendto(pack({"k": "o", "t": msg.get("t")}), addr)
                        except OSError:
                            pass
                    elif k == "o":
                        t0 = msg.get("t")
                        if isinstance(t0, (int, float)):
                            ping_ms = max(0.0, (now - t0) * 1000.0)

                # ---- 3. Приветствия и пинг ----
                if peer is not None:
                    if now - last_hello > (0.5 if now - last_rx > 3.0 else 2.0):
                        last_hello = now
                        try:
                            sock.sendto(pack({"k": "hi", "v": PROTO}), peer)
                        except OSError:
                            pass
                    if now - last_ping > 1.0:
                        last_ping = now
                        try:
                            sock.sendto(pack({"k": "p", "t": now}), peer)
                        except OSError:
                            pass

            connected = (args.mode == "echo") or (now - last_rx < 3.0 and last_rx > 0)
            if connected != was_connected:
                was_connected = connected
                print("[связь] %s" % ("УСТАНОВЛЕНА" if connected else "потеряна / ожидание"))

            # ---- 4. Статус для мода ----
            if now - last_status > 0.5:
                last_status = now
                atomic_write(p_status, {
                    "t": int(time.time()),
                    "version": VERSION,
                    "role": "host" if args.mode in ("host", "echo") else "join",
                    "mode": args.mode,
                    "connected": connected,
                    "peer": ("%s:%d" % peer) if peer else "",
                    "ping_ms": round(ping_ms, 1) if ping_ms is not None else -1,
                    "tx": tx,
                    "rx": rx,
                    "wfail": wfail,
                    **rates.snapshot(now),
                })

            time.sleep(0.003)
    except KeyboardInterrupt:
        print("\nОстановлено.")
    finally:
        atomic_write(p_status, {"t": 0, "connected": False, "role": args.mode})
        if sock is not None:
            sock.close()


if __name__ == "__main__":
    main()
