#!/usr/bin/env python3
"""Opt-in integration check of the signed MCP/embedding helpers with real weights.
Uses only synthetic speech and private temporary configuration. Does not change
production settings. Arguments: MCP executable, downloaded model directory.
"""
import asyncio, fcntl, json, os, pathlib, sys, tempfile, time, wave
from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

async def main():
    executable = pathlib.Path(sys.argv[1]).resolve()
    weights = pathlib.Path(sys.argv[2]).resolve()
    models = [('bge-small', 'bge-small-en-v1.5-f16.gguf'), ('qwen3-0.6b', 'Qwen3-Embedding-0.6B-Q8_0.gguf')]
    with tempfile.TemporaryDirectory(prefix='embedding-mcp-') as temporary:
        base = pathlib.Path(temporary).resolve(); root = base/'calls'; root.mkdir()
        audio = root/'Test.wav'
        with wave.open(str(audio),'wb') as out:
            out.setparams((1,2,16000,1600,'NONE','not compressed')); out.writeframes(b'\0'*3200)
        transcript = root/'Transcripts/run/Transcript.json'; transcript.parent.mkdir(parents=True)
        transcript.write_text(json.dumps(dict(version=2,recording='Test',createdAt='2026-11-15T12:00:00Z',modelID='fixture',modelName='Fixture',modelSHA256='fixture',engine='fixture',language='en',sources={'mixed':'Test.wav'},segments=[dict(source='mixed',start=0,end=5,text='The launch must wait until we finish moving all the customer data to the new database.',timing='segment') ])))
        original = transcript.read_bytes()
        state = base/'state'; state.mkdir(); (state/'Access.json').write_text(json.dumps(dict(version=1,enabled=True,folders=[str(root)])))
        embedding = state/'Embeddings'; model_root = embedding/'Models'; model_root.mkdir(parents=True)
        for _, filename in models: os.link(weights/filename,model_root/filename)
        params = StdioServerParameters(command=str(executable),args=['--state-directory',str(state)])
        async with stdio_client(params) as (read,write):
            async with ClientSession(read,write) as session:
                await session.initialize()
                async def call(name,args):
                    result=await session.call_tool(name,args)
                    assert not result.isError, result.content
                    return result.structuredContent
                off=await call('list_calls',{})
                assert off['search_status']['state']=='disabled'
                for model_id,filename in models:
                    (embedding/'Settings.json').write_text(json.dumps(dict(enabled=True,modelID=model_id)))
                    deadline=time.monotonic()+30
                    while True:
                        progress=await call('list_calls',{})
                        if progress['search_status']['state']=='ready': break
                        assert time.monotonic()<deadline, progress['search_status']
                        await asyncio.sleep(.1)
                    query='What caused the release to be delayed?'
                    result=await call('search_transcripts',{'query':query})
                    assert result['search_status']['mode']=='hybrid',result
                    assert result['search_status']['coverage_complete'] and result['total']==1,result
                    assert result['items'][0]['match']['start_seconds']==0
                    assert result['items'][0]['match']['speaker']=='Mixed audio'
                    assert (await call('search_transcripts',{'query':query,'mode':'keyword'}))['total']==0
                    assert (await call('search_transcripts',{'query':query+' "nonexistent phrase"'}))['total']==0
                    assert (await call('search_transcripts',{'query':query,'speaker':'Recorder'}))['total']==0
                    with (embedding/'priority.lock').open('a') as lease:
                        fcntl.flock(lease,fcntl.LOCK_SH)
                        paused=await call('search_transcripts',{'query':query})
                        assert paused['search_status']['state']=='paused' and paused['search_status']['mode']=='keyword'
                    resumed=await call('search_transcripts',{'query':query})
                    assert resumed['search_status']['mode']=='hybrid'
                    (model_root/filename).unlink()
                    missing=await call('search_transcripts',{'query':'database'})
                    assert missing['search_status']['state']=='missing_model' and missing['total']==1
                    assert transcript.read_bytes()==original
                    print('PASS',model_id,'verified inference, semantic-only hit, citations, quotes, speaker filter, priority pause/resume, model removal and keyword fallback',flush=True)
                (embedding/'Settings.json').write_text(json.dumps(dict(enabled=False,modelID=models[1][0])))
                assert (await call('list_calls',{}))['search_status']['state']=='disabled'
if __name__=='__main__':
    asyncio.run(asyncio.wait_for(main(),timeout=90))
