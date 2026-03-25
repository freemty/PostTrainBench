# claude_v01 → v02: 反思管线驱动的迭代

> 这份文档用人话解释 v02 的每个改动——它观察到了什么、为什么要改、改了之后期望什么效果。

## 背景

v01 是我们手动从 exp00a/01b/02a 的实验日志中提取的第一版 skill。它告诉 agent 一些基本事实（HF 缓存在哪、用什么版本的库、gsm8k 用什么格式训练），但缺少很多从"血泪教训"中才能学到的策略性知识。

v02 是用反思管线（reflection pipeline）自动从 exp02a 的 6 个 job 中提取的。流程是：读 solve_out → 提取 58 条 evidence → 聚合成 18 个 pattern → 生成 12 个改动。每个改动都能追溯到具体的 job、具体的行为、具体的 solve_out 行号。

## 改动 1: 告诉 agent 库的 API 变了（CLAUDE.md）

**观察到的问题**：6/6 个 job 都踩了 TRL 0.27.2 和 transformers 4.57.3 的 API breaking changes。比如 `max_seq_length` 改名叫 `max_length`，`evaluation_strategy` 改叫 `eval_strategy`。每个 agent 都要花 2-15 turns 调试这些报错。

**改了什么**：在 CLAUDE.md 加了一张 API 重命名对照表，列出已知的 6 个 breaking change。

**期望效果**：v02 agent 不应再遇到这些 NameError/TypeError，直接用对的参数名。

## 改动 2: 明确告诉 agent 只有 1 张 GPU（CLAUDE.md）

**观察到的问题**：claude_gsm8k 在容器里跑 `nvidia-smi` 看到 8 张 GPU（因为 GPU 隔离泄漏），然后花了 3 个小时尝试多卡 DDP 训练，反复 OOM。lemma_bfcl 也因为看到多卡而尝试分布式训练导致 OOM。

**表面看是 agent 贪心，实际是环境的锅**——容器隔离没做好让 agent 看到了不属于它的 GPU。

**改了什么**：在 CLAUDE.md 加了明确声明"你只有 1 张 H20 96GB"，并禁止使用 DataParallel/DDP。

**期望效果**：v02 agent 不会尝试多卡训练，省下 1-3h 的调试时间。

## 改动 3: 禁止 sleep 轮询，用 wait（time-budget.md）

**观察到的问题**：claude_gsm8k 用 `sleep 3600` 等待训练完成，浪费了 1-2h。lemma_bfcl 77% 的时间在 sleep-poll 循环里看训练进度，期间什么增值工作都没做。只有 codex 不 sleep——训练完就走。

**改了什么**：在 time-budget skill 里强化了 wait 策略：
- 用 `wait $PID` 或 `tail -f --pid=$PID` 替代 sleep
- 如果必须等，等待期间做有用的事（准备 eval 脚本、检查训练进度）
- 禁止 sleep >60s 超过 3 次

**期望效果**：等待时间从 13%+ 降到 <3%。

## 改动 4: 强制退出策略——50% 时有保底模型（time-budget.md）

**观察到的问题**：5/6 个 job 没有退出策略。claude_gsm8k 一直训练到 session 结束，幸好 checkpoint-5000 merge 救了它（57.9%）。lemma_bfcl 训练到 79% 被 timeout 杀掉，没有 final_model 全损。codex_gsm8k 38 分钟就放弃，浪费了 9h22m。唯一有退出策略的 codex_bfcl 在 89% accuracy 后主动停止，拿了 87%。

**改了什么**：加了三个检查点：
- **50% 预算**：必须有一个可提交的 final_model（"保底模型"）
- **75% 预算**：停止新实验，进入 merge/eval/cleanup
- **启动训练前**：必须算 ETA（steps × sec/step），确认 < 剩余时间的 60%

**期望效果**：v02 agent 在 50% 预算时有 final_model，不会再出现"训练 7 小时但没产出"的情况。

## 改动 5 & 6: 格式对齐优先——先读 eval 源码（gsm8k.md + bfcl.md）

**观察到的问题**：这是 exp02a 最重要的发现。codex_bfcl 用与 evaluate.py 完全相同的 jinja 模板格式化训练数据，拿了 87%（从 base 8%）。而 claude_bfcl 花了 60% 时间搜索数据集，根本没来得及对齐格式就超时了。lemma_gsm8k 混入 MetaMathQA 导致格式噪声，准确率从 32% 掉到 22%。

**400 样本格式对齐 > 40K 样本格式不对齐**——这是量化证据。

**改了什么**：
- gsm8k.md：加了 "format-first protocol"——前 5 turns 必须读 evaluate.py 源码，理解 prompt template 和 answer extraction regex
- bfcl.md：加了 "template-first"——前 5 turns 必须找到并阅读 jinja 模板文件
- 两个 skill 都加了"质量 > 数量"的警告

**期望效果**：v02 agent 在开始准备数据之前就知道目标格式，不会盲目下载大数据集。

## 改动 7: 提交前必须自评估（model-packaging.md）

**观察到的问题**：codex_gsm8k 训练完直接退出，从不验证模型是否可用。结果 LoRA adapter 没 merge + 缺 preprocessor_config.json，整个 10h 报废。相反，codex_bfcl 在提交前跑了 limit-20 和 limit-100 两轮自评估（100% 和 89%），确认可用后才退出。claude_gsm8k 也跑了自评估（48%），确认模型有效后做了额外训练尝试。

**改了什么**：加了两阶段自评估协议：
1. 训练后立即：`evaluate.py --limit 20`（快速 sanity check）
2. 确认可用后：`evaluate.py --limit 100`（更全面验证）
3. 只有两阶段都通过才提交 final_model

**期望效果**：v02 agent 提交的每个 final_model 都至少经过 `--limit 20` 验证，不会再出现"训练成功但 eval 加载失败"。

## 改动 8: 告诉 agent CN 网络的限制（CLAUDE.md）

**观察到的问题**：claude_bfcl 花了 40 分钟盲目搜索数据集——4 次 WebFetch 被防火墙拦截，46 次 load_dataset 试了 60+ 个数据集。而它需要的 hermes-function-calling-v1 就在本地 HF 缓存里，agent 根本不知道。

**改了什么**：在 CLAUDE.md 加了：
- CN 网络约束说明（WebFetch 不可用、HuggingFace 可能不可达）
- HF_HOME 回退路径检测
- 强调"先 `local_files_only=True` 检查本地缓存，再考虑下载"
- 预缓存数据集列表的位置

**期望效果**：v02 agent 失败的 load_dataset 调用不超过 5 次（v01 的 claude_bfcl 有 46 次）。

## 改动 9: SIGTERM 处理器模板（time-budget.md）

**观察到的问题**：lemma_bfcl 的训练在 79% 处被 10h timeout 的 SIGTERM 杀掉，没有保存任何东西。checkpoint-1800 存在但是 LoRA adapter（未 merge），run_task.sh 只认 `final_model/`。如果训练脚本注册了 SIGTERM handler 在被杀前保存模型，这个 job 就能有输出。

**改了什么**：在 time-budget skill 加了 SIGTERM handler 模板代码，以及要求训练时设置合理的 `save_steps`（每 500 步保存一次 checkpoint）。

**期望效果**：80%+ 的 job 注册 SIGTERM handler 或设置 save_steps，被 timeout 杀掉时不会全损。

## 改动 10: 数据扩展决策树（gsm8k.md）

**观察到的问题**：lemma_gsm8k 在第一次训练得到 32% 后，没有先分析为什么，就直接混入 MetaMathQA 希望"更多数据 = 更好效果"。结果反而退化到 22%——跨域数据格式不匹配引入了噪声。之后又盲目尝试 4 epoch、高学习率等，像随机搜索而非 informed decision。

**改了什么**：加了数据扩展决策树：
- 第一轮必须小规模快速验证（<30 min），用自评估确认 pipeline 通畅
- 自评估 > baseline 但不够好 → 保留当前模型作为保底，再加数据
- 自评估 < baseline → 训练策略有问题，不要加数据，先检查格式对齐
- 每次迭代只改一个变量

**期望效果**：v02 agent 在每轮训练后都跑 self-eval，基于结果做 informed decision，不盲目加数据。

## 改动 11: 快速启动协议（CLAUDE.md）

**观察到的问题**：lemma_gsm8k 用了 32 turns（约 1.5h）才开始训练。其中 25 turns 在找 HF cache 路径（环境问题），但即使排除环境问题，lemma 的 phase management 系统本身也增加了很多开销（写计划、更新 todo list、阶段状态变更）。codex 只需 8 turns 就开始训练。

**改了什么**：加了"快速启动协议"——5 步内开始训练：
1. 检查环境（GPU、HF cache、包版本）
2. 读 eval 源码理解目标格式
3. 准备训练数据
4. 写训练脚本
5. 启动训练

**期望效果**：v02 agent 在前 10 turns 内开始第一次训练。

## 改动 12: 禁止 pkill -f（model-packaging.md）

**观察到的问题**：lemma_gsm8k 在清理进程时执行了 `pkill -f python3`，结果杀掉了包括自身在内的所有 Python 进程。在我们的 fleet 环境中，`pkill -f` 更危险——它会匹配 SSH 命令参数，可能杀掉自己的 SSH 连接甚至 sshd。exp02a 之前就因为 pkill 导致 n00 (bastion) 不可达。

**改了什么**：在 model-packaging skill 加了安全进程管理规则：
- 禁止使用 `pkill -f` 或 `killall`
- 正确做法：`pgrep -f <pattern>` 获取 PID → 逐个 `kill -9 <pid>`

**期望效果**：v02 agent 不会使用 pkill -f。

---

## 没做的事（有意留白）

以下 5 个 provisional pattern 没有生成 harness change，因为只在 1 个 job 中出现，证据不足以做通用决策：

1. **pat-014 Adaptive iteration**（codex_bfcl 独有的"试 → 发现太慢 → 缩小 → 成功"模式）—— 好实践但可能是 codex 模型特性
2. **pat-015 pkill danger**（只有 lemma_gsm8k 一个 job）—— 虽然只出现一次，但因为严重性高还是做了改动 12
3. **pat-016 NFS storage issue**（只影响 claude_bfcl）—— 应该在基础设施层修
4. **pat-017 Efficient execution**（codex 的快速执行风格）—— 难以通过 skill 教会
5. **pat-018 Premature exit**（codex_gsm8k 38 分钟就放弃）—— 改动 4 的退出策略已部分覆盖

## 如何验证

跑 A/B 实验：claude_v02 vs claude_v00（零 skill 基线），相同条件（gemma-3-4b-pt, gsm8k + bfcl, 10h）。对比：

| 预测 | 怎么验证 |
|------|---------|
| 前 10 turns 开始训练 | 从 TrajectoryBrief 读 time_to_first_train |
| 不用 sleep >60s 超过 3 次 | grep solve_out |
| 50% 时有 final_model | 检查 5h 时是否存在 final_model/ |
| 前 5 turns 读 eval 源码 | 从 solve_out 确认 |
| 不用 pkill -f | grep solve_out |
| 提交前跑 --limit eval | 从 solve_out 确认 |
| accuracy 高于 v00 | metrics.json |
| 有效训练时间占比提升 | 从 TrajectoryBrief 的 time_allocation |
