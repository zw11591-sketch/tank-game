# -*- coding: utf-8 -*-
"""资源批构建入口。

调用方式（由 tools/build_assets.ps1 包装）：
    blender.exe --background --factory-startup --python tools/blender/build_all.py -- [模块名...]

不带参数则构建全部；带参数时只构建指定模块（tanks / walls / base / props），
便于只改了一个生成器时快速重跑。

每个生成器返回 [(资源名, 三角面数)]，这里汇总成一张报告，
并对照 dims.BUDGET 标出超预算项——面数失控会直接反映到帧率上，
所以把它做成构建产物的一部分，而不是事后再去 Godot 里查。
"""

import sys
import time
from os import path as _p

_HERE = _p.dirname(_p.abspath(__file__))
_ROOT = _p.dirname(_p.dirname(_HERE))
sys.path.append(_HERE)

import dims as D  # noqa: E402

OUT_DIR = _p.join(_ROOT, "assets", "models")

MODULES = ("tanks", "walls", "base", "props")


def _argv():
    """取 `--` 之后的参数。Blender 会把 `--` 前的参数吃掉。"""
    if "--" in sys.argv:
        args = sys.argv[sys.argv.index("--") + 1:]
    else:
        args = []
    picked = [a for a in args if a in MODULES]
    return picked or list(MODULES)


def main():
    wanted = _argv()
    rows = []
    failed = []
    t0 = time.time()

    for name in wanted:
        mod = __import__("gen_" + name)
        print("[build] ==== gen_%s ====" % name, flush=True)
        try:
            rows.extend(mod.build_all(OUT_DIR))
        except Exception as exc:        # 单个模块炸掉不该让整条流水线停住
            import traceback
            traceback.print_exc()
            failed.append("%s: %s" % (name, exc))

    print("\n================ 资源构建报告 ================")
    print("%-22s %10s %10s %s" % ("资源", "三角面", "预算", "状态"))
    over = 0
    for key, tris in rows:
        budget = D.budget_for(key)
        ok = tris <= budget
        over += 0 if ok else 1
        print("%-22s %10d %10d %s" % (key, tris, budget, "OK" if ok else "超预算!"))
    print("----------------------------------------------")
    print("共 %d 个资源，总面数 %d，耗时 %.1fs" % (
        len(rows), sum(t for _, t in rows), time.time() - t0))
    if over:
        print("注意：%d 个资源超出面数预算，建议回头简化。" % over)
    if failed:
        print("失败模块：")
        for f in failed:
            print("  - " + f)
    print("输出目录：" + OUT_DIR)
    print("==============================================")

    # 退出码非 0 时 PowerShell 侧会报错，CI 里也能直接当门禁用
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
