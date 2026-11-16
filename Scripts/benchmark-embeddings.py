#!/usr/bin/env python3
"""Local, small-sample retrieval check. See docs/semantic-search.md for limits."""
import json, pathlib, subprocess, time, math, sys, re
root = pathlib.Path(__file__).resolve().parent.parent
work = root / 'build/embedding-models'
if len(sys.argv) not in (2, 3):
 raise SystemExit("Usage: benchmark-embeddings.py CORPUS.json [CASES.json]")
corpus_path = pathlib.Path(sys.argv[1])
case_path = pathlib.Path(sys.argv[2]) if len(sys.argv) == 3 else corpus_path.with_suffix('.cases.json')
corpus = json.loads(corpus_path.read_text())
if not case_path.is_file():
 raise SystemExit("Supply a local cases JSON file of [question, source anchor] pairs.")
cases = json.loads(case_path.read_text())
if not isinstance(cases, list) or not cases or not all(
    isinstance(pair, list) and len(pair) == 2 and all(isinstance(s, str) and s.strip() for s in pair)
    for pair in cases
):
 raise SystemExit("Expected a nonempty JSON array of [question, source anchor] pairs.")
models = [
 ('bge-small-en-v1.5-f16.gguf', 'cls', 'Represent this sentence for searching relevant passages: '),
 ('Qwen3-Embedding-0.6B-Q8_0.gguf', 'last', 'Instruct: Given a meeting transcript search query, retrieve relevant passages that answer the query\nQuery: '),
]
for model, pooling, prefix in models:
 texts = [x['text'] for x in corpus] + [prefix + q for q, _ in cases]
 vectors=[]; duration=0; rss=[]; footprints=[]
 for i in range(0,len(texts),24):
  input_path=work/'benchmark-input.json'; output_path=work/'benchmark-output.json'; log_path=work/f'benchmark-{pooling}-{i}.log'
  input_path.write_text(json.dumps(texts[i:i+24])); input_path.chmod(0o600)
  start=time.monotonic()
  with log_path.open('w') as log:
   subprocess.run(['/usr/bin/time','-l',str(root/'build/native/EmbeddingWorker'),str(work/model),pooling,str(input_path),str(output_path)],stderr=log,stdout=log,check=True)
  duration+=time.monotonic()-start
  vectors.extend(json.loads(output_path.read_text()))
  contents=log_path.read_text()
  rss.extend(map(int,re.findall(r'(\d+)\s+maximum resident set size',contents)))
  footprints.extend(map(int,re.findall(r'(\d+)\s+peak memory footprint',contents)))
 hits1=hits3=0; ranks=[]
 for n,(question,anchor) in enumerate(cases):
  gold={i for i,c in enumerate(corpus) if anchor.casefold() in c['text'].casefold()}
  if not gold: raise ValueError(f'Missing source anchor: {anchor}')
  query=vectors[len(corpus)+n]
  scores=[sum(a*b for a,b in zip(query,v)) for v in vectors[:len(corpus)]]
  ranking=sorted(range(len(corpus)),key=lambda i:scores[i],reverse=True)
  rank=min(ranking.index(i)+1 for i in gold); ranks.append(rank)
  hits1+=rank==1; hits3+=rank<=3
  print(question, 'rank', rank, 'top scores', [round(scores[i],3) for i in ranking[:3]])
 print(json.dumps(dict(model=model,chunks=len(corpus),queries=len(cases),top1=hits1,top3=hits3,ranks=ranks,seconds=round(duration,3),peakRSSMiB=round(max(rss)/2**20,1),peakFootprintMiB=round(max(footprints)/2**20,1))))
