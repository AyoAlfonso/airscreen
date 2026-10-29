import json, socket, sys, time
host, port = "127.0.0.1", 47890
s = socket.create_connection((host, port), timeout=5)
s.settimeout(8)
s.sendall((json.dumps({"t":"hello","v":1,"id":"mock-tv","name":"Mock TV"})+"\n").encode())
print("sent hello")
start = time.time()
buf = b""
while time.time() - start < 8:
    try:
        data = s.recv(65536)
    except socket.timeout:
        break
    if not data:
        break
    buf += data
    while b"\n" in buf:
        line, buf = buf.split(b"\n", 1)
        if not line.strip(): continue
        try:
            obj = json.loads(line)
            t = obj.get("t")
            print("recv:", t, "len", len(line), "sdp" if t=="offer" else "")
            if t == "offer":
                print("OFFER SDP first lines:")
                print("\n".join(obj.get("sdp","").splitlines()[:8]))
                sys.exit(0)
        except Exception as e:
            print("bad line", e)
print("no offer received")
