"""Redraw docs/figures/refresh-benchmark.png from the measured refresh times.

Numbers are the PostgreSQL 18.4 run on 7 Aug 2026, recorded in the README
and in reports/03_partitioning_and_refresh.md. This script does not query a
database.
"""
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt

HERE = Path(__file__).resolve().parent

def main() -> None:
    fig, ax = plt.subplots(figsize=(7.8, 3.6), dpi=150)
    labels = ["One period  ·  refresh_period(32)", "All 49 periods  ·  refresh_all()"]
    values = [109, 4284]
    colors = ["#2E8B57", "#0B132B"]
    bars = ax.barh([0, 1], values, color=colors, height=0.58)
    ax.set_yticks([0, 1], labels, fontsize=11)
    ax.set_xlabel("Milliseconds", fontsize=11)
    ax.set_xlim(0, 5600)
    ax.set_title("Alert-layer refresh on the Elliptic load", loc="left", fontsize=13, color="#0B132B", pad=16)
    for bar, value in zip(bars, values):
        ax.text(value + 90, bar.get_y() + bar.get_height() / 2, f"{value:,} ms",
                va="center", ha="left", fontsize=11, color="#0B132B")
    ax.spines["top"].set_visible(False)
    ax.spines["right"].set_visible(False)
    ax.tick_params(length=0)
    ax.grid(axis="x", color="#e6e6e6", zorder=0)
    ax.set_axisbelow(True)
    fig.tight_layout()
    out = HERE / "refresh-benchmark.png"
    fig.savefig(out, bbox_inches="tight", facecolor="white")
    print(out)

if __name__ == "__main__":
    main()
