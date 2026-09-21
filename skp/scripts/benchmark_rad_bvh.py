"""Reproducible 100-face RAD benchmark. Uses the production Python pipeline.

The worker redirects only Runner's executable in its isolated process; it never
changes MoosasPy source or replaces the installed engine during measurement.
"""
from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path
import random
import shutil
import statistics
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))

def write_json(path, value):
    Path(path).write_text(json.dumps(value, indent=2, ensure_ascii=False, allow_nan=False), encoding='utf-8')

def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()

def describe(samples):
    return {'median': statistics.median(samples), 'minimum': min(samples), 'maximum': max(samples), 'samples': samples}

def worker(args):
    from MoosasPy.simulation.radiation import calculation
    from skp.scripts import surface_analysis_job as job
    original = calculation.Runner.run_command
    batches = []
    capture = Path(args.capture) if args.capture else None
    if capture:
        capture.mkdir(parents=True, exist_ok=True)
    def redirected(runner, command, *positional, **keywords):
        command = list(command)
        command[0] = args.engine
        started = time.perf_counter()
        result = original(runner, command, *positional, **keywords)
        elapsed = time.perf_counter() - started
        if result.returncode:
            raise RuntimeError(f'RAD exited {result.returncode}: {getattr(result, "stderr", "")}')
        metadata = {'seconds': elapsed}
        if capture:
            ray_file = capture / f'batch-{len(batches):03d}.i'
            hit_file = ray_file.with_suffix('.o')
            shutil.copy2(command[-1], ray_file)
            shutil.copy2(command[command.index('-o') + 1], hit_file)
            metadata.update(input=str(ray_file), output=str(hit_file), rays=len(ray_file.read_text().splitlines()), sha256=digest(ray_file), output_sha256=digest(hit_file))
        batches.append(metadata)
        return result
    calculation.Runner.run_command = redirected
    started = time.perf_counter()
    result = job.execute(args.request)
    elapsed = time.perf_counter() - started
    write_json(Path(args.request).parent / 'metrics.json', {'pipeline_seconds': elapsed, 'engine_seconds': sum(b['seconds'] for b in batches), 'batches': batches})
    if capture:
        write_json(capture / 'batches.json', batches)
    assert result['success']

def benchmark(args):
    # Pin only this benchmark and its children, never the host application.
    # This makes paired timings comparable on hybrid P/E-core Windows CPUs.
    if args.affinity_mask:
        import ctypes
        kernel = ctypes.WinDLL('kernel32', use_last_error=True)
        kernel.GetCurrentProcess.restype = ctypes.c_void_p
        kernel.SetProcessAffinityMask.argtypes = [ctypes.c_void_p, ctypes.c_size_t]
        if not kernel.SetProcessAffinityMask(kernel.GetCurrentProcess(), int(args.affinity_mask, 0)):
            raise ctypes.WinError(ctypes.get_last_error())
    work = Path(args.workload).resolve()
    output = Path(args.output).resolve()
    output.mkdir(parents=True, exist_ok=True)
    engines = {'baseline': str(Path(args.baseline).resolve()), 'bvh': str(Path(args.candidate).resolve())}
    environment = os.environ.copy()
    environment['GOMAXPROCS'] = str(args.threads)
    report = {'threads': args.threads, 'affinity_mask': args.affinity_mask, 'seed': 4217, 'repeats': 5, 'python': sys.version, 'engine_sha256': {k:digest(v) for k,v in engines.items()}, 'analyses': {}}
    native_pool = []
    for mode in ['sunhour', 'radiation']:
        request = json.loads((work / f'{mode}.request.json').read_text(encoding='utf-8'))
        def pipeline(label, tag, capture=False):
            run_dir = output / mode / f'{label}-{tag}'
            run_dir.mkdir(parents=True, exist_ok=True)
            req_file = run_dir / 'request.json'
            write_json(req_file, request)
            command = [sys.executable, str(Path(__file__).resolve()), 'worker', '--engine', engines[label], '--request', str(req_file)]
            if capture:
                command += ['--capture', str(output / mode / 'capture')]
            started = time.perf_counter()
            with (run_dir / 'stdout.log').open('w', encoding='utf-8') as log:
                process = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, env=environment)
            wall = time.perf_counter() - started
            if process.returncode:
                raise RuntimeError(f'Pipeline failed: {run_dir / "stdout.log"}')
            metrics = json.loads((run_dir / 'metrics.json').read_text())
            metrics['wall_seconds'] = wall
            result = json.loads((run_dir / 'result.json').read_text())
            return metrics, result
        print(f'{mode}: capturing frozen rays through baseline pipeline', flush=True)
        _, baseline_result = pipeline('baseline', 'warmup', capture=True)
        _, bvh_result = pipeline('bvh', 'warmup')
        if baseline_result != bvh_result:
            raise AssertionError(f'{mode} analysis results differ')
        batches = json.loads((output / mode / 'capture' / 'batches.json').read_text())
        total_rays = sum(b['rays'] for b in batches)
        combined = output / mode / 'rays.i'
        combined.write_bytes(b''.join(Path(b['input']).read_bytes() for b in batches))
        for batch in batches:
            inputs = Path(batch['input']).read_text().splitlines()
            hits = Path(batch['output']).read_text().splitlines()
            if len(inputs) != len(hits):
                raise AssertionError('Incomplete baseline output')
            native_pool.extend((mode, r, h) for r, h in zip(inputs, hits))
        def engine_run(label, verify=False):
            start = time.perf_counter()
            for index, batch in enumerate(batches):
                hit_file = output / mode / f'{label}-engine-{index:03d}.o'
                completed = subprocess.run([engines[label], '-g', request['scene_path'], '-o', str(hit_file), batch['input']], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, env=environment)
                if completed.returncode:
                    raise RuntimeError(completed.stderr.decode(errors='replace'))
                if verify and digest(hit_file) != batch['output_sha256']:
                    raise AssertionError(f'{mode} batch {index} engine output differs')
            return time.perf_counter() - start
        engine_run('baseline', True)
        engine_run('bvh', True)
        engine_samples = {k:[] for k in engines}
        pipeline_samples = {k:[] for k in engines}
        wall_samples = {k:[] for k in engines}
        for repeat in range(5):
            print(f'{mode}: paired repeat {repeat+1}/5, {total_rays} rays / {len(batches)} batches', flush=True)
            order = ['baseline','bvh'] if repeat % 2 == 0 else ['bvh','baseline']
            for label in order:
                engine_samples[label].append(engine_run(label))
                metrics,result = pipeline(label, str(repeat))
                if result != baseline_result:
                    raise AssertionError(f'{mode} {label} repeat {repeat} result changed')
                pipeline_samples[label].append(metrics['pipeline_seconds'])
                wall_samples[label].append(metrics['wall_seconds'])
        record = {'rays': total_rays, 'batches': len(batches), 'rays_sha256': digest(combined), 'results_equal': True,
                  'engine_seconds': {k:describe(v) for k,v in engine_samples.items()}, 'pipeline_seconds': {k:describe(v) for k,v in pipeline_samples.items()},
                  'python_process_seconds': {k:describe(v) for k,v in wall_samples.items()}}
        for measure in ['engine_seconds','pipeline_seconds','python_process_seconds']:
            record[measure]['speedup'] = record[measure]['baseline']['median']/record[measure]['bvh']['median']
        report['analyses'][mode] = record
        write_json(output / 'report.json', report)
    chosen = random.Random(4217).sample(range(len(native_pool)), min(500,len(native_pool)))
    native_samples = []
    for index,pool_index in enumerate(chosen):
        mode,line,hit = native_pool[pool_index]
        values = [float(v) for v in line.split(',')]
        h = [float(v) for v in hit.split(',')]
        native_samples.append({'index':index,'analysis':mode,'origin':values[:3],'direction':values[3:], 'engine':None if h==[-1.0]*6 else h[:3]})
    write_json(output / 'native_samples.json',native_samples)
    (output / 'native.rays.i').write_text('\n'.join(','.join(map(str,s['origin']+s['direction'])) for s in native_samples)+'\n',encoding='ascii')
    print(json.dumps(report,indent=2),flush=True)

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    commands=parser.add_subparsers(dest='command',required=True)
    worker_parser=commands.add_parser('worker')
    worker_parser.add_argument('--engine',required=True); worker_parser.add_argument('--request',required=True); worker_parser.add_argument('--capture')
    benchmark_parser=commands.add_parser('benchmark')
    for name in ['workload','output','baseline','candidate']:
        benchmark_parser.add_argument('--'+name,required=True)
    benchmark_parser.add_argument('--threads',type=int,default=4)
    benchmark_parser.add_argument('--affinity-mask',help='Windows process mask, e.g. 0x55 for logical CPUs 0,2,4,6; inherited by all children')
    native_parser=commands.add_parser('native')
    native_parser.add_argument('--measurements',required=True)
    native_parser.add_argument('--scene',required=True)
    native_parser.add_argument('--annotate',action='store_true')
    args=parser.parse_args()
    if args.command=='worker': worker(args)
    elif args.command=='benchmark': benchmark(args)
    else: native_validation(args)

def native_validation(args):
    import math
    directory=Path(args.measurements)
    samples=json.loads((directory/'native_samples.json').read_text())
    if args.annotate:
        hits=json.loads((directory/'native.profile.json').read_text())['hits']
        sources=[line.split(',')[2] for line in Path(args.scene).read_text().splitlines() if line.startswith('f,')]
        for sample,hit in zip(samples,hits):
            assert (sample['engine'] is not None)==(hit['face']>=0)
            if hit['face']>=0:
                sample['engine_source']=sources[hit['face']].split('__tri_')[0].removeprefix('surface_').replace('_','/')
        write_json(directory/'native_annotated.json',samples)
        return
    native=json.loads((directory/'native_results.json').read_text())
    hits=json.loads((directory/'native.profile.json').read_text())['hits']
    comparisons=[]
    for sample,result in zip(samples,native):
        assert sample['index']==result['index']
        engine,actual=sample['engine'],result['native']
        distance=math.dist(engine,actual['point']) if engine is not None and actual is not None else None
        agree=(engine is None and actual is None) or (distance is not None and distance<=0.02)
        edge=result.get('engine_face') or actual or {}
        tolerance=(not agree and edge.get('boundary_distance') is not None and edge['boundary_distance']<=0.02)
        projected=(not agree and hits[sample['index']].get('projected_boundary',False) and hits[sample['index']].get('projected_edge_distance',1)>0 and hits[sample['index']].get('projected_edge_distance',1)<=0.01)
        comparisons.append({'index':sample['index'],'agreement':agree,'boundary_tolerance':tolerance or projected,'projected_tolerance':projected,'distance':distance,'engine':engine,'native':actual,'engine_face':result.get('engine_face'),'projection':hits[sample['index']]})
    report={'count':len(comparisons),'agree':sum(c['agreement'] for c in comparisons),'boundary_cases':[c for c in comparisons if c['boundary_tolerance']],
            'unresolved':[c for c in comparisons if not c['agreement'] and not c['boundary_tolerance']], 'position_tolerance_m':0.02}
    write_json(directory/'native_comparison.json',report)
    print(json.dumps(report,indent=2))

if __name__=='__main__':
    main()
