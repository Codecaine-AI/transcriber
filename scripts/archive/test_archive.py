import contextlib
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import sqlite3
import sys
import tempfile
import unittest
import uuid

sys.path.insert(0, str(Path(__file__).parent))
from archive import Archive, safe_id


class ArchiveTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.base = Path(self.temp.name)
        self.archive = Archive(self.base/'archive', self.base/'cache')

    def tearDown(self):
        self.archive.db.close()
        self.temp.cleanup()

    def test_large_audio_null_dates_all_fields_and_dictionary_survive(self):
        source=self.base/'flow.sqlite'
        db=sqlite3.connect(source)
        db.executescript('''create table History(transcriptEntityId text, timestamp text, asrText text,
            formattedText text, editedText text, audio blob, opusChunks text, builtInAudio blob,
            customInteger integer, customReal real, extraPayload blob, additionalContext text);
            create table Dictionary(phrase text, customField blob);''')
        uid=str(uuid.uuid4())
        audio=b'RIFF'+b'0'* (9*1024*1024)
        db.execute('insert into History values(?,?,?,?,?,?,?,?,?,?,?,?)',
            (uid,None,'raw words','Clean words.','user edit',audio,'[1,2]',b'unknown',47,1.25,b'\xff\x00','{"x": 5}'))
        db.execute('insert into History(transcriptEntityId, timestamp, asrText) values(?,?,?)',(None,None,'orphan transcript'))
        db.execute('insert into Dictionary values(?,?)',('custom',b'\x00\xff'))
        db.commit();db.close()
        before=hashlib.sha256(source.read_bytes()).hexdigest()
        self.assertEqual(self.archive.import_sqlite(source),2)
        m=self.archive.load('wispr-flow',uid)
        self.assertIsNone(m['timestamp'])
        self.assertEqual(m['text']['raw'],'raw words')
        self.assertEqual(m['text']['clean'],'Clean words.')
        wav=next(a for a in m['artifacts'] if a['kind']=='audio')
        self.assertEqual(wav['bytes'],len(audio))
        self.assertEqual(wav['sha256'],hashlib.sha256(audio).hexdigest())
        folder=self.archive.record_dir('wispr-flow',uid)
        v=json.loads((folder/m['source_versions'][0]['path']).read_text())['values']
        self.assertEqual(v['customInteger'],{'type':'integer','value':47})
        self.assertEqual(v['extraPayload'],{'type':'blob','base64':'/wA='})
        self.assertEqual(v['additionalContext']['value'],'{"x": 5}')
        self.assertEqual(v['builtInAudio']['bytes'],7)
        self.assertEqual(before,hashlib.sha256(source.read_bytes()).hexdigest())
        orphan=self.archive.load('wispr-flow','missing-id:flow.sqlite:2')
        self.assertEqual(orphan['text']['raw'],'orphan transcript')
        self.assertEqual(self.archive.import_sqlite(source),2)
        self.assertEqual(len(self.archive.load('wispr-flow',uid)['source_versions']),1)
        self.assertEqual(self.archive.verify()['records'],2)
        self.assertEqual(len(list((self.archive.root/'sources/wispr-flow').glob('dictionary-*.json'))),1)

    def test_media_versions_and_transcriber_updates_are_retained(self):
        uid=str(uuid.uuid4());source=self.base/'transcriber';folder=source/'generations'/uid;folder.mkdir(parents=True)
        audio=b'audio bytes'
        (folder/'inference.wav').write_bytes(audio)
        native={'id':uid,'status':'completed','mode':'dictation','createdAt':'2026-09-16T12:00:00Z',
            'rawText':'raw','finalText':'Clean.','device':{'id':'my-mac'},
            'inferenceAudio':{'filename':'inference.wav'},'settings':{'language':'en'}}
        p=folder/'metadata.json';p.write_text(json.dumps(native))
        self.assertEqual(self.archive.sync_transcriber(source),1)
        self.assertEqual(self.archive.sync_transcriber(source),0)
        native['delivery']={'status':'inserted'};p.write_text(json.dumps(native))
        self.assertEqual(self.archive.sync_transcriber(source),1)
        m=self.archive.load('transcriber',uid)
        self.assertEqual(len(m['source_versions']),2)
        self.assertEqual(len(m['artifacts']),1)
        p.unlink()
        self.archive.sync_transcriber(source)
        self.assertEqual(self.archive.verify()['records'],1)
        self.assertEqual(self.archive.load('transcriber',uid)['text']['raw'],'raw')

    def test_export_integrity_metadata_and_original_files_are_preserved(self):
        root=self.base/'export';record=root/'records/unknown/unknown/unknown/x';record.mkdir(parents=True)
        uid=str(uuid.uuid4());audio=b'x'*(9*1024*1024)
        (record/'audio.wav').write_bytes(audio)
        (record/'raw_transcript.txt').write_text('source raw')
        metadata={'id':uid,'text':{'asr':'source raw','formatted':'Clean text'},'timestamps':{'timestamp_utc':None},
            'context':{'app':'test app'},'integrity':{'source_row_sha256':'original hash'},
            'files':{'audio':'audio.wav','raw_transcript':'raw_transcript.txt'},
            'media':{'audio':{'sha256':hashlib.sha256(audio).hexdigest()}}}
        (record/'metadata.json').write_text(json.dumps(metadata))
        (root/'manifest.json').write_text('{"counts":{"records":1}}')
        self.assertEqual(self.archive.import_wisprsync(root),1)
        m=self.archive.load('wispr-flow',uid)
        version=self.archive.record_dir('wispr-flow',uid)/m['source_versions'][0]['path']
        self.assertEqual(json.loads(version.read_text()),metadata)
        self.assertTrue(self.archive.verify()['passed'])
        artifact=self.archive.record_dir('wispr-flow',uid)/m['artifacts'][0]['path']
        artifact.write_bytes(b'corruption')
        with self.assertRaisesRegex(ValueError,'integrity'):
            self.archive.verify()

    def test_failed_transcriber_copy_is_retried_and_cache_is_rebuildable(self):
        uid=str(uuid.uuid4());source=self.base/'transcriber';folder=source/'generations'/uid;folder.mkdir(parents=True)
        m={'id':uid,'status':'completed','createdAt':'2026-09-16T12:00:00Z','rawText':'raw',
            'finalText':'clean','inferenceAudio':{'filename':'inference.wav'}}
        (folder/'metadata.json').write_text(json.dumps(m))
        with self.assertRaises(ValueError):self.archive.sync_transcriber(source)
        self.assertEqual(self.archive.state,{})
        (folder/'inference.wav').write_bytes(b'audio')
        self.assertEqual(self.archive.sync_transcriber(source),1)
        self.archive.db.execute('delete from records');self.archive.db.commit()
        self.archive.reindex()
        self.assertEqual(self.archive.summary()['sources'][0]['records'],1)

    def test_identifiers_cannot_escape_record_directory(self):
        for identifier in ['../../outside',None,'','source-'+ 'a'*64]:
            p=self.archive.record_dir('wispr-flow',identifier)
            self.assertTrue(p.is_relative_to(self.archive.root/'records/wispr-flow'))
            self.assertEqual(safe_id(safe_id(identifier)),safe_id(identifier))


class ViewerTests(unittest.TestCase):
    def test_search_pagination_media_ranges_and_local_access(self):
        import subprocess
        import socket
        import time
        import urllib.request
        import urllib.error
        with tempfile.TemporaryDirectory() as temp:
            base=Path(temp);root=base/'archive';cache=base/'cache';data=base/'transcriber';data.mkdir()
            a=Archive(root,cache)
            evidence=root/'sources'/'dictionary.json'
            evidence.parent.mkdir()
            evidence.write_text('{"rows": []}')
            for n in range(55):
                m=a.load('transcriber',str(uuid.uuid4()))
                m.update(timestamp='2026-09-16T12:00:00Z',text={'raw':f'raw {n}', 'clean':f'clean {n}'},status='completed')
                if n==54:
                    folder=a.record_dir('transcriber',m['id'])
                    artifact=a.blob(folder,io.BytesIO(b'RIFF0123456789'),'audio','.wav','sample.wav')
                    a.add_artifact(m,artifact);file_path=folder.relative_to(root.resolve()).as_posix()+'/'+artifact['path']
                    wanted=m['source']+'/'+m['id']
                a.save(m)
            a.commit();a.db.close()
            with socket.socket() as sock:
                sock.bind(('127.0.0.1',0));port=sock.getsockname()[1]
            process=subprocess.Popen([sys.executable,str(Path(__file__).parent/'archive.py'),'--root',str(root),'--cache',str(cache),'serve','--transcriber-data',str(data),'--port',str(port)],stdout=subprocess.DEVNULL,stderr=subprocess.PIPE)
            address=f'http://127.0.0.1:{port}'
            try:
                for _ in range(100):
                    try:
                        with urllib.request.urlopen(address+'/api/summary',timeout=2) as response:summary=json.load(response)
                        break
                    except OSError:time.sleep(.05)
                else:self.fail('Viewer failed to start')
                self.assertEqual(summary['sources'][0]['records'],55)
                with urllib.request.urlopen(address+'/api/dataset') as response:dataset=json.load(response)
                self.assertEqual(dataset['dataset']['format'],'codecaine-transcripts')
                self.assertEqual(dataset['source_files'][0]['path'],'sources/dictionary.json')
                with urllib.request.urlopen(address+'/files/sources/dictionary.json') as response:
                    self.assertEqual(json.load(response),{'rows':[]})
                with urllib.request.urlopen(address+'/api/records') as response:page=json.load(response)
                self.assertEqual(page['total'],55);self.assertEqual(len(page['items']),50)
                with urllib.request.urlopen(address+'/api/records?q=raw%2054') as response:result=json.load(response)
                self.assertEqual(result['items'][0]['key'],wanted)
                req=urllib.request.Request(address+'/files/'+file_path,headers={'Range':'bytes=4-7'})
                with urllib.request.urlopen(req) as response:
                    self.assertEqual(response.status,206);self.assertEqual(response.read(),b'0123')
                for headers in [{'Host':'attacker.example'},{'Origin':'https://attacker.example'}]:
                    with self.assertRaises(urllib.error.HTTPError) as error:
                        urllib.request.urlopen(urllib.request.Request(address+'/api/summary',headers=headers))
                    self.assertEqual(error.exception.code,403)
                with self.assertRaises(urllib.error.HTTPError) as error:
                    urllib.request.urlopen(address+'/files/%2E%2E/%2E%2E/etc/passwd')
                self.assertEqual(error.exception.code,404)
            finally:
                process.terminate();process.wait(timeout=5);process.stderr.close()

if __name__=='__main__':unittest.main()
