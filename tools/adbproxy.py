import socket, threading, sys
LISTEN=('127.0.0.1',5556)
TARGET=('192.168.0.30',5555)
def relay(a,b):
    try:
        while True:
            d=a.recv(65536)
            if not d: break
            b.sendall(d)
    except Exception: pass
    finally:
        try: a.close()
        except: pass
        try: b.close()
        except: pass
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1); s.bind(LISTEN); s.listen(5)
print('proxy listening', flush=True)
while True:
    c,_=s.accept()
    t=socket.create_connection(TARGET,timeout=10)
    threading.Thread(target=relay,args=(c,t),daemon=True).start()
    threading.Thread(target=relay,args=(t,c),daemon=True).start()
