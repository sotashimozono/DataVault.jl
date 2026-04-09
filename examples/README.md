# Examples

## VanDerPol — DataVault + ParamIO の統合デモ

Van der Pol 方程式を題材に、ParamIO によるパラメータ展開と DataVault によるファイル管理の
一連のワークフローを示す。

### 構成

```
examples/
├── configs/
│   └── vanderpol.toml      # ParamIO config (mu を sweep)
├── src/
│   └── VanDerPol.jl        # RK4 ODE ソルバー + 観測量抽出 (外部依存なし)
└── scripts/
    ├── compute.jl           # 計算ループ (DataVault で save!/mark_done!)
    └── analysis/
        └── summarize.jl    # μ ごとの amplitude/period 集計
```

### 実行方法

```bash
cd DataVault.jl/
julia --project=. examples/scripts/compute.jl
julia --project=. examples/scripts/analysis/summarize.jl
```

### 確認できること

- `path_keys = ["system.mu"]` → `out/data/vanderpol/sysmu1.00/` 形式のパス生成
- `.done` ファイルによる冪等性 (2回目は Pending: 0)
- `build_ledger` による `ledger.csv` 生成
- `record_figure` による `meta.toml` 生成
- 物理的な正しさ: amplitude ≈ 2.0 (极限サイクルの既知の値)、μ 増加でperiod増加
