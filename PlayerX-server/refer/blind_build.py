#!/usr/bin/env python3
"""盲评正向分发：N 个模型的输出视频 → 每样本独立随机排列为 A/B/C → 分组 → 生成盲评目录。

用法: python3 blind_build.py config.json [seed]
"""
import csv
import hashlib
import json
import random
import shutil
import sys
from pathlib import Path


# ═════════════════════════════════════════════════════════════════════════════
#  工具
# ═════════════════════════════════════════════════════════════════════════════

def label_names(n):
    return [chr(ord("A") + i) for i in range(n)]


def group_names(n):
    return [f"g{i}" for i in range(1, n + 1)]


def md5(p):
    return hashlib.md5(p.read_bytes()).hexdigest()


def resolve_samples(cfg):
    if cfg.get("samples"):
        return sorted(cfg["samples"])
    return sorted(set(range(1, 101)) - set(cfg.get("exclude_samples", [])))


# ═════════════════════════════════════════════════════════════════════════════
#  分组
# ═════════════════════════════════════════════════════════════════════════════

def assign_groups(samples, n_groups, rng):
    """随机打散后均匀分配。前 extra 组多分 1 个。"""
    pool = list(samples)
    rng.shuffle(pool)
    base, extra = divmod(len(pool), n_groups)
    assn, i = {}, 0
    for gi in range(n_groups):
        g, size = f"g{gi+1}", base + 1 if gi < extra else base
        for n in pool[i: i+size]:
            assn[n] = g
        i += size
    return assn


def reuse_groups(samples, reuse_csv):
    """从旧 map 文件复用分组（换模型不换人）。"""
    with Path(reuse_csv).open(encoding="utf-8-sig") as f:
        ref = {int(r["filename"].rsplit(".", 1)[0]): r["group"] for r in csv.DictReader(f)}
    missing = set(samples) - set(ref)
    assert not missing, f"reuse 源缺样本: {sorted(missing)}"
    return {n: ref[n] for n in samples}


# ═════════════════════════════════════════════════════════════════════════════
#  前置检查
# ═════════════════════════════════════════════════════════════════════════════

def check_sources(src_dir, models, samples):
    """验证所有模型目录下都有完整的样本文件。"""
    need = {f"{n}.mp4" for n in samples}
    assert src_dir.is_dir(), f"源目录不存在: {src_dir}"
    for m in models:
        d = src_dir / m
        assert d.is_dir(), f"模型目录不存在: {d}"
        missing = need - {p.name for p in d.glob("*.mp4")}
        assert not missing, f"{m}: 缺{len(missing)}文件 {sorted(missing)[:10]}"


def load_prompts(comp, samples):
    """加载 prompt.csv，返回 {样本编号: row}。"""
    with Path(comp["prompt_csv"]).open(encoding="utf-8-sig", newline="") as f:
        rows = list(csv.DictReader(f))
    by_n = {}
    for r in rows:
        by_n[int(r["Image"].rsplit(".", 1)[0])] = r
    missing = set(samples) - set(by_n)
    assert not missing, f"prompt.csv 缺样本: {sorted(missing)}"
    return by_n


# ═════════════════════════════════════════════════════════════════════════════
#  核心：盲评目录构建
# ═════════════════════════════════════════════════════════════════════════════

def copy_blind(samples, group_of, models, labels, src_dir, dst_dir, comp,
               prompt_by_n, prompt_cols, ff_dir, rng):
    """每样本独立排列 → 复制到 A/B/C → 写 prompt.csv → 返回 map_rows。"""
    groups = sorted(set(group_of.values()), key=lambda x: int(x[1:]))

    # 创建目录
    if dst_dir.exists():
        shutil.rmtree(dst_dir)
    for g in groups:
        for lb in labels:
            (dst_dir / g / lb).mkdir(parents=True, exist_ok=True)
        if comp:
            (dst_dir / g / "first_frames").mkdir(parents=True, exist_ok=True)

    # 复制视频
    map_rows = []
    for n in samples:
        fn, g = f"{n}.mp4", group_of[n]
        perm = models[:]
        rng.shuffle(perm)

        row = {"group": g, "filename": fn}
        for lb, model in zip(labels, perm):
            shutil.copy2(src_dir / model / fn, dst_dir / g / lb / fn)
            row[f"{lb}_source"] = model
        map_rows.append(row)

        if comp and n in prompt_by_n:
            shutil.copy2(ff_dir / f"{n}.png", dst_dir / g / "first_frames" / f"{n}.png")

    # 各组 prompt.csv
    if comp:
        for g in groups:
            ns = sorted(n for n, gg in group_of.items() if gg == g)
            with (dst_dir / g / "prompt.csv").open("w", newline="", encoding="utf-8") as f:
                w = csv.DictWriter(f, fieldnames=prompt_cols)
                w.writeheader()
                for n in ns:
                    w.writerow({k: prompt_by_n[n][k] for k in prompt_cols})

    return map_rows


def copy_direct(samples, models, src_dir, dst_dir, rng):
    """非盲评：直接按真实模型名平铺。"""
    for n in samples:
        fn = f"{n}.mp4"
        for model in models:
            (dst_dir / model).mkdir(parents=True, exist_ok=True)
            shutil.copy2(src_dir / model / fn, dst_dir / model / fn)


# ═════════════════════════════════════════════════════════════════════════════
#  自检
# ═════════════════════════════════════════════════════════════════════════════

def verify(dst_dir, src_dir, models, labels, group_of, map_rows, comp):
    """组大小、排列完整、MD5、杂散文件、配套对齐、map 不泄漏。"""
    groups = sorted(set(group_of.values()), key=lambda x: int(x[1:]))
    ok = True

    # 组大小
    for g in groups:
        expect = sum(1 for v in group_of.values() if v == g)
        actual = sum(1 for r in map_rows if r["group"] == g)
        if actual != expect:
            print(f"  FAIL 组{g}大小: {actual} (期望{expect})")
            ok = False

    # 排列完整 + MD5
    on_disk = {g: {lb: set() for lb in labels} for g in groups}
    for r in map_rows:
        sources = [r[f"{lb}_source"] for lb in labels]
        if set(sources) != set(models):
            print(f"  FAIL 排列 {r['filename']}: {sources}")
            ok = False
            continue
        g, fn = r["group"], r["filename"]
        for lb in labels:
            model = r[f"{lb}_source"]
            a, b = dst_dir / g / lb / fn, src_dir / model / fn
            if not a.exists() or md5(a) != md5(b):
                print(f"  FAIL MD5 {a}")
                ok = False
            on_disk[g][lb].add(fn)

    # 杂散文件
    for g in groups:
        for lb in labels:
            actual = {p.name for p in (dst_dir / g / lb).glob("*.mp4")}
            if actual != on_disk[g][lb]:
                print(f"  FAIL 杂散 {g}/{lb}: {actual ^ on_disk[g][lb]}")
                ok = False

    # 配套文件三方交叉
    if comp:
        for g in groups:
            expect = {f"{n}.png" for n, gg in group_of.items() if gg == g}
            ff = {p.name for p in (dst_dir / g / "first_frames").glob("*.png")}
            if ff != expect:
                print(f"  FAIL first_frames {g}: {ff ^ expect}")
                ok = False
            with (dst_dir / g / "prompt.csv").open(encoding="utf-8-sig") as f:
                c = {r["Image"] for r in csv.DictReader(f)}
            if c != expect:
                print(f"  FAIL prompt.csv {g}: {c ^ expect}")
                ok = False
            mp4 = {p.stem+".png" for p in (dst_dir / g / labels[0]).glob("*.mp4")}
            if mp4 != expect:
                print(f"  FAIL mp4不一致 {g}: {mp4 ^ expect}")
                ok = False

    # map 不泄漏
    leaked = list(dst_dir.rglob("map*"))
    if leaked:
        print(f"  FAIL map泄漏: {leaked}")
        ok = False

    print(f"\n{'全部通过!' if ok else '自检发现问题'} 输出: {dst_dir}/")


# ═════════════════════════════════════════════════════════════════════════════
#  写 map CSV
# ═════════════════════════════════════════════════════════════════════════════

def write_map(map_csv, map_rows, labels):
    cols = ["group", "filename"] + [f"{lb}_source" for lb in labels]
    map_csv.parent.mkdir(parents=True, exist_ok=True)
    with map_csv.open("w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=cols)
        w.writeheader()
        w.writerows(map_rows)
    print(f"map -> {map_csv}  ← 保密！不要发给评分员")


# ═════════════════════════════════════════════════════════════════════════════
#  顶层：构建盲评
# ═════════════════════════════════════════════════════════════════════════════

def build(cfg, seed_override=None):
    src_dir = Path(cfg["src_model_dir"])
    dst_dir = Path(cfg["dst_dir"])
    map_csv = Path(cfg["map_csv"])
    models = cfg["models"]
    labels = label_names(len(models))
    n_groups = cfg.get("n_groups", 1)
    blind = cfg.get("blind", True)
    comp = cfg.get("companions", {})

    samples = resolve_samples(cfg)
    prompt_by_n = load_prompts(comp, samples) if comp else {}
    prompt_cols = comp.get("prompt_cols", ["Image", "prompt", "en_prompt"])
    ff_dir = Path(comp.get("first_frames_dir", "."))

    seed = seed_override if seed_override is not None else cfg.get("seed")
    rng = random.Random(seed)
    print(f"样本:{len(samples)}  模型:{len(models)}  组:{n_groups}  盲评:{blind}")

    check_sources(src_dir, models, samples)

    mode = cfg.get("group_mode", "fresh")
    if mode == "reuse":
        group_of = reuse_groups(samples, cfg["reuse_map_csv"])
    else:
        group_of = assign_groups(samples, n_groups, rng)
    print(group_of)
    if blind:
        map_rows = copy_blind(samples, group_of, models, labels, src_dir, dst_dir,
                              comp, prompt_by_n, prompt_cols, ff_dir, rng)
        write_map(map_csv, map_rows, labels)
        verify(dst_dir, src_dir, models, labels, group_of, map_rows, comp)
    else:
        copy_direct(samples, models, src_dir, dst_dir, rng)
        print(f"非盲评，直接复制到 {dst_dir}/ 完成")


# ═════════════════════════════════════════════════════════════════════════════
#  入口
# ═════════════════════════════════════════════════════════════════════════════

def main():
    if len(sys.argv) < 2:
        print("用法: python3 blind_build.py config.json [seed]")
        sys.exit(1)
    cfg = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
    seed = int(sys.argv[2]) if len(sys.argv) > 2 else None
    build(cfg, seed)


if __name__ == "__main__":
    main()
