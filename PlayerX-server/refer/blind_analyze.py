#!/usr/bin/env python3
"""盲评反向分析：收集评分后解析、审计、排名。

用法:
  python3 blind_analyze.py analyze config.json    # 解析评分 → deanon CSV
  python3 blind_analyze.py verify  config.json    # 独立审计 (L1 文件 + L2 数据)
  python3 blind_analyze.py rank    config.json    # 模型排名
"""
import csv
import hashlib
import json
import math
import sys
from collections import Counter, defaultdict
from itertools import combinations
from pathlib import Path
from statistics import mean, pstdev


def load_csv(path):
    with open(path, encoding="utf-8-sig", newline="") as f:
        return list(csv.DictReader(f))


def md5(p):
    return hashlib.md5(p.read_bytes()).hexdigest()


def label_names(n):
    return [chr(ord("A") + i) for i in range(n)]


def resolve_samples(cfg):
    """从配置解析样本列表。"""
    if cfg.get("samples"):
        return sorted(cfg["samples"])
    exclude = set(cfg.get("exclude_samples", []))
    return sorted(set(range(1, 101)) - exclude)


# ═══════════════════════════════════════════════════════════════════════
#  analyze: Filter → Dedup → De-anonymize
# ═══════════════════════════════════════════════════════════════════════

def cmd_analyze(cfg):
    src_dir = Path(cfg["src_model_dir"])
    dst_dir = Path(cfg["dst_dir"])
    map_path = Path(cfg["map_csv"])
    raw_path = Path(cfg["raw_csv"])
    deanon_csv = dst_dir / cfg.get("deanon_csv", "playerx_selected_deanon.csv")

    models = cfg["models"]
    labels = label_names(len(models))
    dims = cfg.get("dims", ["multi_总分"])
    tag = cfg.get("tag", "")
    samples = resolve_samples(cfg)
    expect = {f"{n}.mp4" for n in samples}
    exclude = set(cfg.get("exclude_raters", []))

    # 读取 map
    map_rows = load_csv(map_path)
    src_of = {r["filename"]: r for r in map_rows}     # filename → {group, A_source, ...}
    grp_of = {r["filename"]: r["group"] for r in map_rows}

    # Filter: tag + A/B/C + 样本集内 + 未排除评分员
    raw = load_csv(raw_path)
    for r in raw:
        r["folder"] = r["folder"].split("/")[-1]   # 兼容 folder 为完整路径的导出
    filtered = []
    n_excl = 0
    for r in raw:
        ok = (r.get("tag", "") == tag and r["folder"] in labels
              and r["file_name"] in expect and r.get("rater", "") not in exclude)
        if ok:
            filtered.append(r)
        elif ok_except_rater := (r.get("tag", "") == tag and r["folder"] in labels
                                 and r["file_name"] in expect and r.get("rater", "") in exclude):
            n_excl += 1
    dropped = len(raw) - len(filtered) - n_excl
    print(f"原始:{len(raw)} → 筛选:{len(filtered)} (无关:{dropped} 排除评分员:{n_excl} {sorted(exclude)})")

    # Dedup: 取每 key 最新 updated_at
    use_dim_key = len(dims) > 1
    latest = {}
    for r in filtered:
        key = (r["rater"], r["file_name"], r["folder"], r.get("slide_type", "")) \
            if use_dim_key else (r["rater"], r["file_name"], r["folder"])
        if key not in latest or r["updated_at"] > latest[key]["updated_at"]:
            latest[key] = r
    clean = list(latest.values())
    print(f"去重后:{len(clean)} (移除 {len(filtered) - len(clean)})")

    # De-anonymize: A/B/C → 真实模型
    deanon = []
    for r in clean:
        m = src_of.get(r["file_name"])
        if not m:
            continue
        r = dict(r)
        r["group"] = m["group"]
        r["model"] = m[f"{r['folder']}_source"]
        r["eval_mode"] = "blind"
        deanon.append(r)

    cols = list(clean[0].keys()) + ["group", "model", "eval_mode"]
    with deanon_csv.open("w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=cols)
        w.writeheader()
        w.writerows(deanon)
    print(f"deanon → {deanon_csv} ({len(deanon)} 行)")

    # 每样本评分人数分布
    if use_dim_key or cfg.get("rater_distribution"):
        raters_of = defaultdict(set)
        for r in deanon:
            raters_of[r["file_name"]].add(r["rater"])

        dist = []
        for n in samples:
            fn = f"{n}.mp4"
            names = sorted(raters_of.get(fn, set()))
            dist.append({"file_name": fn, "group": grp_of.get(fn, ""),
                         "n_raters": len(names), "raters": ";".join(names)})

        dist_csv = dst_dir / "sample_rater_distribution.csv"
        with dist_csv.open("w", newline="", encoding="utf-8") as f:
            w = csv.DictWriter(f, fieldnames=["file_name", "group", "n_raters", "raters"])
            w.writeheader()
            w.writerows(dist)

        cnt = Counter(d["n_raters"] for d in dist)
        all_n = [d["n_raters"] for d in dist]
        print(f"\n{'─'*40}\n每样本评分人数分布:")
        for nr in sorted(cnt):
            print(f"  {nr}人 → {cnt[nr]}样本")
        print(f"  共{len(dist)}样本, min={min(all_n)}, max={max(all_n)}, mean={sum(all_n)/len(all_n):.1f}")

        # 维度完整性
        if use_dim_key:
            seen = defaultdict(set)
            for r in deanon:
                seen[(r["rater"], r["file_name"])].add(r.get("slide_type", ""))
            gaps = [(k, set(dims) - v) for k, v in seen.items() if v != set(dims)]
            if gaps:
                print(f"\n维度缺失: {len(gaps)} 对")
                by_rater = defaultdict(list)
                for (rater, fn), miss in gaps:
                    by_rater[rater].append((fn, miss))
                for rater in sorted(by_rater):
                    items = by_rater[rater]
                    all_miss = sorted({d for _, ms in items for d in ms})
                    print(f"  {rater}: {len(items)}样本 缺{all_miss}")
            else:
                print("维度完整性: OK")

    print("analyze 完成")


# ═══════════════════════════════════════════════════════════════════════
#  verify: 独立审计 (L1 磁盘文件 + L2 数据行)
# ═══════════════════════════════════════════════════════════════════════

def cmd_verify(cfg):
    src_dir = Path(cfg["src_model_dir"])
    dst_dir = Path(cfg["dst_dir"])
    map_path = Path(cfg["map_csv"])
    raw_path = Path(cfg["raw_csv"])
    deanon_csv = dst_dir / cfg.get("deanon_csv", "playerx_selected_deanon.csv")

    models = set(cfg["models"])
    labels = label_names(len(models))
    dims = cfg.get("dims", ["multi_总分"])
    tag = cfg.get("tag", "")
    samples = resolve_samples(cfg)
    expect = {f"{n}.mp4" for n in samples}
    exclude = set(cfg.get("exclude_raters", []))
    n_groups = cfg.get("n_groups", 1)
    groups = [f"g{i}" for i in range(1, n_groups + 1)]

    ok = True

    # ── L1: map ↔ 磁盘文件 ──
    print("=== L1: map ↔ 磁盘文件 ===")
    map_rows = load_csv(map_path)
    on_disk = {g: {lb: set() for lb in labels} for g in groups}
    for r in map_rows:
        sources = [r[f"{lb}_source"] for lb in labels]
        if set(sources) != models:
            print(f"  FAIL 排列 {r['filename']}")
            ok = False
        g, fn = r["group"], r["filename"]
        for lb in labels:
            model = r[f"{lb}_source"]
            blind_f = dst_dir / g / lb / fn
            src_f = src_dir / model / fn
            if not blind_f.exists():
                print(f"  MISSING {blind_f}")
                ok = False
                continue
            if md5(blind_f) != md5(src_f):
                print(f"  MD5 FAIL {blind_f}")
                ok = False
            on_disk[g][lb].add(fn)

    for g in groups:
        for lb in labels:
            actual = {p.name for p in (dst_dir / g / lb).glob("*.mp4")}
            if actual != on_disk[g][lb]:
                print(f"  STRAY {g}/{lb}: {actual ^ on_disk[g][lb]}")
                ok = False
    print("L1:", "OK" if ok else "FAIL")

    # ── L2: deanon CSV ↔ 独立重新推导 ──
    print("\n=== L2: deanon CSV ↔ 独立推导 ===")
    l2_ok = True
    src_of = {r["filename"]: r for r in map_rows}
    use_dim_key = len(dims) > 1

    # 独立 filter + dedup（完全不用 analyze 的输出）
    raw = load_csv(raw_path)
    for r in raw:
        r["folder"] = r["folder"].split("/")[-1]   # 兼容 folder 为完整路径的导出
    filtered = [r for r in raw
                if r.get("tag", "") == tag and r["folder"] in labels
                and r["file_name"] in expect and r.get("rater", "") not in exclude]
    latest = {}
    for r in filtered:
        key = (r["rater"], r["file_name"], r["folder"], r.get("slide_type", "")) \
            if use_dim_key else (r["rater"], r["file_name"], r["folder"])
        if key not in latest or r["updated_at"] > latest[key]["updated_at"]:
            latest[key] = r

    # 独立 de-anonymize
    recomputed = {}
    for key, r in latest.items():
        m = src_of.get(r["file_name"])
        if not m:
            continue
        recomputed[key] = {
            "updated_at": r["updated_at"], "rater": r["rater"],
            "file_name": r["file_name"], "folder": r["folder"],
            "stars": r.get("stars", ""), "slide_type": r.get("slide_type", ""),
            "group": m["group"], "model": m[f"{r['folder']}_source"],
            "eval_mode": "blind",
        }

    # 加载 deanon CSV，用同样 key 索引
    deanon_rows = load_csv(deanon_csv)
    deanon_by_key = {}
    for r in deanon_rows:
        key = (r["rater"], r["file_name"], r["folder"], r.get("slide_type", "")) \
            if use_dim_key else (r["rater"], r["file_name"], r["folder"])
        deanon_by_key[key] = r

    # 比对 key 集合
    if set(recomputed) != set(deanon_by_key):
        miss = set(recomputed) - set(deanon_by_key)
        ext = set(deanon_by_key) - set(recomputed)
        print(f"  FAIL key集合: 缺{len(miss)} 多{len(ext)}")
        l2_ok = False

    # 逐 key 逐字段比对
    check = ["updated_at", "rater", "file_name", "stars", "slide_type", "group", "model", "eval_mode"]
    mismatches = 0
    for key in recomputed:
        if key not in deanon_by_key:
            continue
        a, b = recomputed[key], deanon_by_key[key]
        for f in check:
            if str(b.get(f, "")) != str(a.get(f, "")):
                mismatches += 1
                if mismatches <= 5:
                    print(f"  字段不一致 {key}[{f}]: 期望={a[f]!r} 实际={b.get(f)!r}")
                l2_ok = False
                break

    print(f"  推导:{len(recomputed)}  deanon:{len(deanon_by_key)}  不一致:{mismatches}")
    print("L2:", "OK" if l2_ok else "FAIL")
    if not l2_ok:
        ok = False
    print(f"\n{'='*20} 总审计: {'全部通过' if ok else '有问题'} {'='*20}")


# ═══════════════════════════════════════════════════════════════════════
#  rank: Bradley-Terry + 成对显著性
# ═══════════════════════════════════════════════════════════════════════

def sign_test_p(k, n):
    """双边 exact binomial test, p0=0.5, 对数空间防溢出。"""
    if n == 0:
        return 1.0
    m = min(k, n - k)
    nln2 = n * math.log(0.5)
    terms = [math.lgamma(n+1) - math.lgamma(x+1) - math.lgamma(n-x+1) + nln2
             for x in range(m+1)]
    hi = max(terms)
    return min(2 * math.exp(hi) * sum(math.exp(t-hi) for t in terms), 1.0)


def bradley_terry(model_set, wins, ties):
    """MM 迭代拟合 Bradley-Terry 模型。"""
    W = {m: 0.0 for m in model_set}
    N = {}
    for i, j in combinations(model_set, 2):
        wi, wj = wins.get((i, j), 0), wins.get((j, i), 0)
        t = ties.get(frozenset((i, j)), 0)
        W[i] += wi + 0.5*t
        W[j] += wj + 0.5*t
        N[frozenset((i, j))] = wi + wj + t

    bt = {m: 1.0 for m in model_set}
    for _ in range(10000):
        new = {}
        for i in model_set:
            denom = sum(N.get(frozenset((i, j)), 0) / (bt[i]+bt[j])
                        for j in model_set if j != i)
            new[i] = (W[i]/denom) if denom else bt[i]
        gm = math.exp(sum(math.log(v) for v in new.values()) / len(new))
        for k in new:
            new[k] /= gm
        if max(abs(new[k]-bt[k]) for k in model_set) < 1e-12:
            bt = new
            break
        bt = new
    return bt


def cmd_rank(cfg):
    dst_dir = Path(cfg["dst_dir"])
    deanon_csv = dst_dir / cfg.get("deanon_csv", "playerx_selected_deanon.csv")

    rows = load_csv(deanon_csv)
    blind = [r for r in rows if r.get("eval_mode") == "blind"]
    model_set = sorted(set(r["model"] for r in blind))
    if len(model_set) < 2:
        sys.exit("至少需要 2 个模型")

    # 按 (评分员, 样本) 分组，只保留完整组
    groups = defaultdict(dict)
    for r in blind:
        groups[(r["rater"], r["file_name"])][r["model"]] = int(r["stars"])
    complete = [sc for sc in groups.values() if set(sc) == set(model_set)]
    G = len(complete)
    print(f"模型:{model_set}  完整组(评分员×样本):{G}")

    # 每模型分数
    scores = defaultdict(list)
    for sc in complete:
        for m in model_set:
            scores[m].append(sc[m])

    # 成对胜/负/平
    wins = defaultdict(int)
    ties = defaultdict(int)
    for sc in complete:
        for i, j in combinations(model_set, 2):
            if sc[i] > sc[j]:
                wins[(i, j)] += 1
            elif sc[j] > sc[i]:
                wins[(j, i)] += 1
            else:
                ties[frozenset((i, j))] += 1

    bt = bradley_terry(model_set, wins, ties)
    bt_sum = sum(bt.values())
    bt_pct = {m: bt[m]/bt_sum for m in model_set}
    bt_elo = {m: 400*math.log10(bt[m]) for m in model_set}
    bt_rank = {m: r+1 for r, m in enumerate(sorted(model_set, key=lambda x: -bt[x]))}

    # ── 打印 ──
    print(f"\n{'模型':44s} {'n':>4s}  {'均值':>6s}  {'95%CI':>18s}  {'强度':>6s}  {'Elo':>7s}  {'排名'}")
    print("-"*105)
    for m in sorted(model_set, key=lambda x: -bt[x]):
        s = scores[m]
        mu = mean(s)
        h = 1.96 * pstdev(s) / math.sqrt(len(s))
        print(f"{m:44s} {len(s):4d}  {mu:6.3f}  [{mu-h:7.3f}, {mu+h:7.3f}]  "
              f"{bt_pct[m]:6.3f}  {bt_elo[m]:+7.1f}  {bt_rank[m]:4d}")

    n_pairs = len(list(combinations(model_set, 2)))
    bonf = 0.05 / n_pairs
    print(f"\n{'对比':50s} {'A胜':>5s} {'B胜':>5s} {'平':>4s} {'signP':>8s}  显著(.05/{bonf:.4f})")
    print("-"*90)
    for i, j in combinations(model_set, 2):
        wi = wins.get((i, j), 0)
        wj = wins.get((j, i), 0)
        t = ties.get(frozenset((i, j)), 0)
        sp = sign_test_p(wi, wi+wj) if (wi+wj) > 0 else 1.0
        flag = "**" if sp < bonf else "*" if sp < .05 else "ns"
        print(f"{i+' vs '+j:50s} {wi:5d} {wj:5d} {t:4d} {sp:8.4f}  {flag}")
    print(f"\n  ** p<{bonf:.4f}(Bonf)  * p<.05  ns=不显著")

    # ── 写 CSV ──
    rank_csv = dst_dir / "model_ranking.csv"
    pair_csv = dst_dir / "pairwise_significance.csv"

    with rank_csv.open("w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=[
            "模型", "样本数", "均值", "CI95下", "CI95上", "BT强度", "BT_Elo", "BT排名"])
        w.writeheader()
        for m in sorted(model_set, key=lambda x: -bt[x]):
            s = scores[m]
            mu = mean(s)
            h = 1.96*pstdev(s)/math.sqrt(len(s))
            w.writerow({"模型": m, "样本数": len(s), "均值": round(mu, 4),
                        "CI95下": round(mu-h, 4), "CI95上": round(mu+h, 4),
                        "BT强度": round(bt_pct[m], 4), "BT_Elo": round(bt_elo[m], 1),
                        "BT排名": bt_rank[m]})

    with pair_csv.open("w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=[
            "模型A", "模型B", "A胜", "B胜", "平", "A胜率", "B胜率", "signP",
            "显著.05", f"显著{bonf:.4f}"])
        w.writeheader()
        for i, j in combinations(model_set, 2):
            wi = wins.get((i, j), 0)
            wj = wins.get((j, i), 0)
            t = ties.get(frozenset((i, j)), 0)
            sp = sign_test_p(wi, wi+wj) if (wi+wj) > 0 else 1.0
            w.writerow({"模型A": i, "模型B": j, "A胜": wi, "B胜": wj, "平": t,
                        "A胜率": round(wi/G, 4), "B胜率": round(wj/G, 4),
                        "signP": round(sp, 6),
                        "显著.05": int(sp < .05), f"显著{bonf:.4f}": int(sp < bonf)})

    print(f"结果保存: {rank_csv}  |  {pair_csv}")


# ═══════════════════════════════════════════════════════════════════════
#  主入口
# ═══════════════════════════════════════════════════════════════════════

def main():
    if len(sys.argv) < 3:
        print("用法:")
        print("  python3 blind_analyze.py analyze config.json")
        print("  python3 blind_analyze.py verify  config.json")
        print("  python3 blind_analyze.py rank    config.json")
        sys.exit(1)

    action = sys.argv[1]
    cfg = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))

    dispatch = {"analyze": cmd_analyze, "verify": cmd_verify, "rank": cmd_rank}
    if action not in dispatch:
        sys.exit(f"未知操作: {action}，可选 analyze / verify / rank")
    dispatch[action](cfg)


if __name__ == "__main__":
    main()
