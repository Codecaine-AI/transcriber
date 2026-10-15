"""Read-only localhost data viewer and durable Transcriber archive worker."""
from __future__ import annotations
import json
import mimetypes
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit, parse_qs, unquote


def serve(archive, transcriber_data, port):
    if not 1 <= port <= 65535:
        raise ValueError('Invalid port')
    # A derived index can always be reconstructed from the portable record files.
    archive.reindex()
    stop = threading.Event()
    def worker():
        while not stop.is_set():
            try:
                archive.sync_transcriber(transcriber_data)
            except Exception as error:
                archive.last_error = str(error)
            stop.wait(3)
    thread = threading.Thread(target=worker, daemon=True)
    thread.start()

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass  # Never log transcript searches or record contents.

        def write_headers(self, status, kind, size, extra=None):
            self.send_response(status)
            self.send_header('Content-Type', kind)
            self.send_header('Content-Length', str(size))
            self.send_header('Cache-Control', 'no-store')
            self.send_header('X-Content-Type-Options', 'nosniff')
            self.send_header('Content-Security-Policy', "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self'; media-src 'self'; connect-src 'self'; frame-ancestors 'none'")
            if extra:
                for k,v in extra.items():
                    self.send_header(k,v)
            self.end_headers()

        def json(self, value, status=200):
            data = json.dumps(value, ensure_ascii=False).encode()
            self.write_headers(status,'application/json; charset=utf-8',len(data))
            self.wfile.write(data)

        def do_GET(self):
            try:
                host = self.headers.get('Host', '')
                if host not in (f'127.0.0.1:{port}', f'localhost:{port}'):
                    return self.json({'error':'Local access only'},403)
                origin = self.headers.get('Origin')
                if origin and origin != 'http://' + host:
                    return self.json({'error':'Cross-origin requests are not allowed'},403)
                if self.headers.get('Sec-Fetch-Site') == 'cross-site':
                    return self.json({'error':'Cross-site requests are not allowed'},403)
                url = urlsplit(self.path)
                query = parse_qs(url.query)
                if url.path == '/api/summary':
                    return self.json(archive.summary())
                if url.path == '/api/dataset':
                    documents = {}
                    for name in ('dataset', 'migration', 'verification', 'completeness'):
                        p = archive.root / (name + '.json')
                        if p.is_file():
                            documents[name] = json.loads(p.read_text())
                    documents['source_files'] = [
                        {'path': p.relative_to(archive.root).as_posix(), 'bytes': p.stat().st_size}
                        for p in sorted((archive.root / 'sources').rglob('*'))
                        if p.is_file() and p.resolve().is_relative_to(archive.root / 'sources')]
                    return self.json(documents)
                if url.path == '/api/records':
                    q = query.get('q',[''])[0][:1000]
                    source = query.get('source',[''])[0]
                    offset = max(0,int(query.get('offset',['0'])[0]))
                    where=[]; args=[]
                    if q:
                        term='%' + q.replace('\\','\\\\').replace('%','\\%').replace('_','\\_') + '%'
                        where.append("(raw like ? escape '\\' or clean like ? escape '\\' or app like ? escape '\\')")
                        args += [term]*3
                    if source:
                        where.append('source=?');args.append(source)
                    clause=' where '+' and '.join(where) if where else ''
                    with archive.lock:
                        count=archive.db.execute('select count(*) from records'+clause,args).fetchone()[0]
                        rows=archive.db.execute('select key,source,timestamp,status,app,substr(clean,1,180),audio,screenshot from records'+clause+' order by timestamp desc,key limit 50 offset ?',args+[offset]).fetchall()
                    return self.json({'total':count,'offset':offset,'items':[dict(zip(('key','source','timestamp','status','app','preview','audio','screenshot'),r)) for r in rows]})
                if url.path == '/api/record':
                    key=query.get('key',[''])[0]
                    with archive.lock:
                        row=archive.db.execute('select path from records where key=?',(key,)).fetchone()
                    if row is None:
                        return self.json({'error':'Record not found'},404)
                    folder=(archive.root/row[0]).resolve()
                    if not folder.is_relative_to(archive.root):
                        return self.json({'error':'Invalid record path'},400)
                    metadata=json.loads((folder/'metadata.json').read_text())
                    versions=[]
                    for entry in metadata.get('source_versions',[]):
                        p=(folder/entry['path']).resolve()
                        if not p.is_relative_to(folder):
                            raise ValueError('Invalid source version path')
                        versions.append({**entry,'data':json.loads(p.read_text())})
                    return self.json({'metadata':metadata,'versions':versions,'base':row[0]})
                if url.path.startswith('/files/'):
                    path=(archive.root/unquote(url.path[len('/files/'):])).resolve()
                    if not any(path.is_relative_to(archive.root/part) for part in ('records', 'sources')) or not path.is_file():
                        return self.json({'error':'File not found'},404)
                    kind=mimetypes.guess_type(path.name)[0] or 'application/octet-stream'
                    return self.send_file(path,kind,artifact=True)
                assets={'/':'index.html','/app.js':'app.js','/style.css':'style.css'}
                if url.path in assets:
                    p=Path(__file__).parent/assets[url.path]
                    return self.send_file(p,mimetypes.guess_type(p.name)[0] or 'text/plain')
                return self.json({'error':'Not found'},404)
            except (BrokenPipeError,ConnectionResetError):
                pass
            except (ValueError,KeyError):
                self.json({'error':'Invalid request'},400)
            except Exception:
                self.json({'error':'Archive data could not be read. Check the archive service log.'},500)

        def send_file(self,path,kind,artifact=False):
            size=path.stat().st_size
            start=0; end=size-1; status=200
            value=self.headers.get('Range')
            if value and size:
                if not value.startswith('bytes=') or ',' in value:
                    return self.json({'error':'Invalid byte range'},416)
                left,right=value[6:].split('-',1)
                if not left:
                    start=max(0,size-int(right))
                else:
                    start=int(left)
                    if right:end=min(int(right),size-1)
                if start<0 or start>end or start>=size:
                    return self.json({'error':'Byte range outside file'},416)
                status=206
            extra={'Accept-Ranges':'bytes'}
            if status==206:extra['Content-Range']=f'bytes {start}-{end}/{size}'
            # Unknown artifacts are downloaded rather than interpreted as active pages.
            if artifact and kind not in ('application/json','text/plain','audio/x-wav','audio/wav','image/png'):
                kind='application/octet-stream'
                extra['Content-Disposition']='attachment'
            length=max(0,end-start+1)
            self.write_headers(status,kind,length,extra)
            with path.open('rb') as f:
                f.seek(start)
                while length:
                    data=f.read(min(1024*1024,length))
                    if not data:break
                    self.wfile.write(data);length-=len(data)

    server=ThreadingHTTPServer(('127.0.0.1',port),Handler)
    print(f'Transcript data viewer: http://127.0.0.1:{port}',flush=True)
    try:
        server.serve_forever()
    finally:
        stop.set();server.server_close();thread.join(timeout=10)
