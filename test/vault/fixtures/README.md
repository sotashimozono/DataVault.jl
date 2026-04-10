# test/vault/fixtures/

このディレクトリのファイルは **write-once** です。

## ルール

- 既存ファイルは **絶対に編集しないこと**。
- 新しいスキーマバージョンを追加する場合は、新しいファイル
  （例: `log_v2.toml`）として追加する。
- 既存ファイルが現役の reader で読めなくなったら、それは reader 側の
  バグであって、fixture を直すべきではない。

## 目的

`log_v*.toml` 系の fixture は、**過去のバージョンで書かれた log.toml が、
未来の DataVault でも引き続き読めること** を CI で保証するためにある。
これらを編集してしまうと、forward compat の保証が失われる。

## 一覧

| ファイル | 用途 |
| --- | --- |
| `study.toml`              | テスト用の汎用 config（編集可、テスト調整に使ってよい） |
| `log_v1.toml`             | log.toml v1 の正規 fixture。`read_log_toml` の v1 reader 担保 |
| `log_v99_unknown.toml`    | 未知バージョンを reader が明示的 reject することの検証 |
| `log_v1_missing_meta.toml`| `[meta]` envelope 欠損時のエラー検証 |
