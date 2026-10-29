#!/usr/bin/env python3
"""Rebuild report figures from archived FPGA reports; never run or alter RTL."""
import hashlib
import json
from pathlib import Path

import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib import font_manager

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'docs/report_assets'
RECORDS=[
    ('A','原乘法器＋原取指','benchmarks/results/coremark_board_20261028/old_multiplier_performance.json'),
    ('B','Radix-4 乘法器＋原取指','benchmarks/results/coremark_board_20261028/new_multiplier_performance.json'),
    ('C','Radix-4 乘法器＋三槽取指','benchmarks/results/coremark_board_fetch_three_slots_20261029/on_performance.json'),
]


def main():
    OUT.mkdir(parents=True,exist_ok=True)
    font=Path('C:/Windows/Fonts/msjh.ttc')
    if font.exists():
        font_manager.fontManager.addfont(str(font))
        plt.rcParams['font.family']=font_manager.FontProperties(fname=str(font)).get_name()
    plt.rcParams.update({'font.size':11,'axes.unicode_minus':False,'svg.fonttype':'path',
                         'axes.spines.top':False,'axes.spines.right':False})
    rows=[]
    for version,label,path in RECORDS:
        source=ROOT/path
        r=json.loads(source.read_text(encoding='utf-8'))
        cm=r['benchmark'];meta=r['metadata'];c=r['counters']
        assert r['validation']=='PASS' and cm['crc_pass'] and cm['timing_qualified']
        assert cm['run_kind']==0 and cm['data_size']==2000
        assert meta['features']==(3 if version=='C' else 0)
        assert meta['core_hz']==50_000_000 and (meta['ic_bytes'],meta['dc_bytes'],meta['l2_bytes'])==(8192,8192,16384)
        rows.append({'version':version,'label':label,'source':path,
            'source_sha256':hashlib.sha256(source.read_bytes()).hexdigest(),
            'firmware_sha256':r['mem_sha256'],'iterations':cm['iterations'],
            'kernel_us_per_iteration':cm['ticks_us']/cm['iterations'],
            'iterations_per_second':cm['iterations_per_second'],'iterations_per_second_per_mhz':cm['per_mhz'],
            'main_cpi':r['metrics']['cpi'],
            'wait_percent_main_cycles':{k:100*c[k]/c['cycles'] for k in ['frontend_wait','memory_wait','multiply_wait','load_use_wait']}})
    assert len({r['firmware_sha256'] for r in rows})==1
    comparisons={}
    for a,b in [(0,1),(1,2),(0,2)]:
        ratio=rows[b]['iterations_per_second']/rows[a]['iterations_per_second']
        comparisons[f'{rows[a]["version"]}_to_{rows[b]["version"]}']={
            'speedup':ratio,'throughput_increase_percent':100*(ratio-1),
            'time_reduction_percent':100*(1-1/ratio)}
    summary={'date':'2026-10-29','source':'FPGA UART, CoreMark performance seed',
        'core_hz':50_000_000,'cache_bytes':{'I':8192,'D':8192,'L2':16384},
        'measurement_count_per_configuration':1,'versions':rows,'comparisons':comparisons,
        'notes':['Kernel time divided by timed iterations; main counters include calibration/output.',
                 'Wait counters overlap. Their percentages must not be stacked or summed.',
                 'Single run per configuration; no run-to-run uncertainty estimate.']}
    (OUT/'summary.json').write_text(json.dumps(summary,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    labels=[r['version'] for r in rows]
    colors=['#8A99AD','#337FB5','#16826E']
    def save(fig,name):
        fig.savefig(OUT/(name+'.svg'),bbox_inches='tight',facecolor='white')
        fig.savefig(OUT/(name+'.png'),dpi=200,bbox_inches='tight',facecolor='white')
        plt.close(fig)
    fig,ax=plt.subplots(figsize=(8,4.6))
    values=[r['iterations_per_second'] for r in rows]
    ax.bar(labels,values,color=colors,width=.56)
    ax.set(title='三版實板 CoreMark 吞吐量（越高越好）',ylabel='iterations / second',ylim=(0,60))
    ax.bar_label(ax.containers[0],labels=[f'{v:.3f}' for v in values],padding=5)
    ax.grid(axis='y',alpha=.18);ax.set_axisbelow(True)
    fig.text(.5,-.02,'A：原乘法器／原取指　 B：Radix-4／原取指　 C：Radix-4／三槽取指',ha='center',fontsize=10)
    fig.text(.5,-.075,'50 MHz；I/D/L2＝8/8/16 KiB；相同映像；每版各一次實板量測',ha='center',fontsize=10)
    save(fig,'coremark_throughput')

    fig,ax=plt.subplots(figsize=(8,4.6))
    values=[r['kernel_us_per_iteration']/1000 for r in rows]
    ax.bar(labels,values,color=colors,width=.56)
    ax.set(title='每次 CoreMark 迭代時間（越低越好）',ylabel='milliseconds / iteration',ylim=(0,43))
    ax.bar_label(ax.containers[0],labels=[f'{v:.3f} ms' for v in values],padding=5)
    ax.grid(axis='y',alpha=.18);ax.set_axisbelow(True)
    fig.text(.5,-.02,'A：原乘法器／原取指　 B：Radix-4／原取指　 C：Radix-4／三槽取指',ha='center',fontsize=10)
    fig.text(.5,-.075,'A/B 各 400 次、C 1100 次；以 kernel time / iterations 正規化',ha='center',fontsize=10)
    save(fig,'coremark_iteration_time')

    fig,ax=plt.subplots(figsize=(9,4.8))
    keys=['frontend_wait','memory_wait','multiply_wait','load_use_wait']
    x=list(range(4));w=.34
    for row,offset,color in [(rows[1],-w/2,colors[1]),(rows[2],w/2,colors[2])]:
        v=[row['wait_percent_main_cycles'][k] for k in keys]
        bars=ax.bar([n+offset for n in x],v,width=w,label=row['version'],color=color)
        ax.bar_label(bars,labels=[f'{a:.2f}%' for a in v],padding=4,fontsize=10)
    ax.set_xticks(x,keys)
    ax.set(title='取指改善前後：各等待事件占整段 main cycles',ylabel='percent of main cycles',ylim=(0,94))
    ax.legend(title='B：原取指／C：三槽取指',frameon=False)
    ax.grid(axis='y',alpha=.18);ax.set_axisbelow(True)
    fig.text(.5,-.015,'等待事件可重疊，不能相加；本圖涵蓋整段 main，與 timed kernel 範圍不同。',ha='center',fontsize=10)
    save(fig,'wait_events')
    print('PASS: archived reports verified; summary.json and 3 SVG/PNG figure pairs generated')


if __name__=='__main__':
    main()
