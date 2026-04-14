# 方法说明（Method）

本文记录本项目已实现的优化方法、引入原因与运行方式，是“我们改了什么、为什么这样改”的单一事实来源。

## 术语

- Global 剪枝：文件级剪枝（基于 MANIFEST/SST 级元数据）。
- Local 剪枝：SST 内部的块级/键级剪枝。
- VM：virtual-merge 路径（`file_level_time_bucket_rtree_enable`），通过预计算候选 SST 加速前向扫描。
- Auto：根据查询时间跨度阈值在运行时决定是否启用 VM。

## 动机：按查询范围约束文件访问（而不是“遍历 Version 里的所有 SST”）

原生 RocksDB 暴露的是 **Version**（LSM 快照：每层有哪些 SST），但默认读路径不会把**时空查询窗**作为“必须打开/迭代哪些文件”的一等过滤条件。对于窗口查询，我们希望迭代器只消费与当前查询相关的文件级元数据，并避免对不可能贡献结果的 SST 做 `OpenTable` 或完整前向推进。

这不是“只从磁盘加载半个 Version 结构体”（内存中的 `Version`/`FileMetaData` 图仍可能完整存在），而是读路径层面的**访问收缩**：一次查询真正访问的 SST 集应缩小到由扩展元数据（`st_file_meta`、skip mask、候选索引表）导出的候选子集，而不是对快照中的全部文件执行近似全量扫描行为。

因此，本分支在 manifest 侧字段、`ReadOptions.experimental_st_prune_scan` 以及 `LevelIterator` 的前向跳过逻辑上做了扩展，提供了原生 RocksDB 默认不具备的**查询感知型文件级剪枝**。

## 阶段 A：Global 三态判定

- 增加三态重叠结果：
  - `kDisjoint`：跳过文件
  - `kIntersect`：保持常规 Local 剪枝
  - `kContains`：查询窗完全覆盖文件元数据边界
- 结果通过 `ReadOptions.experimental_st_prune_scan.file_level_overlap_result` 传递。

## 阶段 B：Contains 短路（绕过 Local 路径）

- 当文件重叠状态为 `kContains` 时，关闭该文件的 Local ST 工作：
  - `block_level_enable = false`
  - `key_level_enable = false`
- 在 `BlockBasedTableIterator` 增加物理快路径：
  - 通过 `file_level_overlap_result` 检测 `kContains`
  - 跳过 `AdvanceIndexPastPrunedForward` 调用
  - 跳过 key 级前向剪枝激活与检查
- 安全约束：不绕过 checksum，也不破坏 InternalKey 正确性语义。

## 阶段 C：VM 候选列表加速

- 增加由 VM skip mask 派生的候选 SST 列表：
  - `EnsureStCandidateFilesFromSkipMask()`
  - `NextForwardFileIndexSkippingStPrune()` 在候选表上用 `lower_bound`
- 收益：在多 SST 工作负载下减少前向扫描的迭代器抖动与空转。

## 阶段 D：基准 CLI 的 VM 控制

- 在 `st_meta_read_bench` 增加参数：
  - `--virtual-merge`
  - `--virtual-merge-auto`
  - `--vm-time-span-sec-threshold`
- 组合规则：
  - 最终 VM 启用条件 = `manual || auto_hit`

## 阶段 E：选择性 Local 剪枝（动态门控）

- 在 `sst_manifest` 模式中新增动态 key 级门控：
  - `--sst-manifest-adaptive-key-gate`
  - `--adaptive-overlap-threshold`
- 目的：在高重叠场景（尤其 736 SST）避免“过度剪枝开销”，同时在有效场景保留 Local 过滤能力。

## 当前 736 场景推荐配置

- `--prune-mode sst_manifest`
- `--virtual-merge --virtual-merge-auto --vm-time-span-sec-threshold 21600`
- `--sst-manifest-key-level 1 --sst-manifest-adaptive-key-gate --adaptive-overlap-threshold 0.5`
- `--time-bucket-count 736 --rtree-leaf-size 8`

说明：当 VM 常开时，`manual_VM || auto_hit` 会使 **VM + Auto** 在“是否开启 bucket/R-tree 路径”这个决策上出现冗余。建议二选一：短窗场景显式开 VM；或按真实查询跨度调 Auto 阈值（见 `EXPERIMENTS_AND_SCRIPTS.md` 与无锡 random12 cov 窗口）。

## 重构方向（后续演进）

1. **策略语义收敛（VM vs Auto）**  
   VM 关闭时由 Auto 独立决策；VM 打开时表示“强制走文件级 bucket/R-tree 路径”。避免将 “VM+Auto” 文档化为两个互相独立特性——当前实现是同一个布尔 OR（`st_meta_read_bench`）。

2. **更强的文件级跳过（不增加 Local 成本）**  
   持续投入低成本的 manifest 侧谓词（disjoint/intersect/contains）与“候选表 + 跳转”机制。`NextForwardFileIndexSkippingStPrune` 中被禁用的 SIMD/时间掩码快路径，仅在 profiling 证明迭代器开销主导时再回看。

3. **Seek / 反向迭代**  
   当前主优化路径是前向 `Next`；Seek 密集负载仍需明确语义（另文档记录）。后续可按产品需求补齐 seek 上一致的 ST 感知跳过行为。

4. **“整份 Version”与“按时间分区”**  
   RocksDB 的 **Version** 是 compaction 快照，不是业务时间分区。若要在 DB 粒度“忽略其他时间段”，需要应用层的多目录/多 CF/路由方案；本分支当前仍聚焦单 DB 下的文件级剪枝增强。

5. **命名**  
   建议重命名或补充文档解释 **VirtualMerge**，避免被误解为“虚拟 SST 合并”；代码上它主要用于门控 `file_level_time_bucket_rtree_enable` 及相关预热钩子。

6. **评测口径**  
   在“正确性 vs 速度”叙述中，区分 **Vanilla** 壁钟与 **fork full**；段键结果需持续区分 MBR 口径与点级真值（`EXPERIMENTS_AND_SCRIPTS.md` §0.1a）。

## 复现命令（仅 736）

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "D:\Project\tools\st_prune_vs_full_baseline_sweep.ps1" `
  -RocksDbPathsCsv "D:\Project\data\verify_wuxi_segment_736sst" `
  -WindowsCsv "D:\Project\tools\st_validity_experiment_windows_wuxi.csv" `
  -PruneMode sst_manifest `
  -SstManifestKeyLevel 1 -SstManifestAdaptiveKeyGate -AdaptiveOverlapThreshold 0.5 `
  -VirtualMerge -VirtualMergeAuto -VmTimeSpanSecThreshold 21600 `
  -TimeBucketCount 736 -RTreeLeafSize 8 `
  -FullScanMode window `
  -OutTsv "D:\Project\data\experiments\wuxi_736_focus\ablation_736_best_adapt05.tsv" `
  -VerifyKVResults
```

## Compaction 实现防撞梁（稳定性优先）

本节记录面向生产落地的 compaction 执行规则，目标是在保留查询性能收益的同时，避免噪声误触发、过度切分与 IO 抖动。

### 1）空间切分动作：明确 Soft / Hard 的物理行为

- **软切分（Soft Limit）**  
  当空间污染信号首次超阈，不立即封盘；在最近的安全 Data Block 边界落切点，保证块完整性并提升查询对齐稳定性。

- **硬切分（Hard Limit）**  
  当污染失控（例如 MBR 膨胀倍数明显异常）时，无论当前文件是否达到常规填充目标，都立即 `Finish()` 封盘。

- **实现提示**  
  切分触发判断建议放在 Data Block flush 粒度（而不是每条 key），以控制 CPU 开销并降低高频决策噪声。

### 2）IneffScore 分母保护：空查询单独建模

主评分保持不变：

`IneffScore = OpenedFiles / (ReturnedKeys + epsilon)`

但对于空查询窗口（`ReturnedKeys == 0`），不应直接依赖该比值，需单独维护误判通道：

- **FPR 通道**  
  若文件频繁被 Global 判定为相交，但 Local 评估长期无有效命中，应视为文件 MBR 空洞/过宽的强信号。

- **调度影响**  
  对持续高 FPR 的桶/文件，应提升到最高修复优先级（merge-repartition / compaction repair lane），即便常规 IneffScore 样本较少。

### 3）Shadow Budget 平滑切换：避免预算阶跃引发 IO 冲击

预算不应从低档直接跳到高档（如 5% -> 25%），应使用爬坡控制：

- **Stepper 规则**  
  按固定速率渐进调整 compaction 修复预算（例如每秒 1%-2%）。

- **原因**  
  可抑制后台 IO 振荡，降低策略切换期间前台 P99 延迟抖动。

- **实现建议**  
  保留现有 token-bucket 模型，在其前面增加时间维度的目标预算斜坡控制（`current_budget` 以有界斜率逼近 `target_budget`）。

## 主要改动文件

- `rocksdb/include/rocksdb/options.h`
- `rocksdb/db/version_set.cc`
- `rocksdb/table/block_based/block_based_table_iterator.cc`
- `rocks-demo/st_meta_read_bench.cpp`
- `tools/st_prune_vs_full_baseline_sweep.ps1`
- `docs/BEST_736_CONFIG.md`
- `docs/st_ablation_wuxi_1sst_vs_manysst.html`
