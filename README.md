# Claw keeper

中文在前，English below.

---

## 这是什么

`keeper.sh` 是娃娃机金库的守护程序。它在 GitHub Actions 上每 5 分钟跑一遍（接力运行，见下文「运行方式」），每遍把工厂创建的**每个**金库都处理一次（新金库会被自动发现，不用改配置），分两轮：先清完所有金库的结算队列，再给所有金库超时没锚的枪定锚。开奖有期限，定锚没有，所以一个金库的扫描不会拖慢另一个金库的开奖。

1. **从队首清结算队列。** 队首那一枪的锚块已出（状态 4，可开奖）或锚块哈希已过期（状态 6），就调用 `settleFallback(队首)`。每枪一笔交易，严格按队列顺序，每笔都显式给 3,000,000 gas 上限（金库在转账 gas 不够时整笔回滚，所以不能用节点的估算值）。可开奖的枪按锚定时已定好的金额开奖，奖金直接打给开枪的玩家；计价币拒绝这笔转账（或玩家那边拒收）时，这一枪照样开完，奖金留在金库里记在玩家名下（`Owed` 事件），玩家自己调用 `withdrawOwed(收款地址)` 领取，日志里这一枪会注明。已过期的枪只做关闭，不赔付。每个金库每遍最多处理 `SWEEP_MAX`（500）枪，剩下的下一遍继续。
2. **给超时没锚的枪定锚。** 从这个金库的低水位标记开始往 `nextShotId` 扫，每个金库每遍最多读 `ARM_MAX`（500）枪。开枪 6 小时后还没有锚块的枪（状态 2）调用 `armFallback`，下一遍锚块出了再开奖。新标记是本遍第一枪还没锚的编号；扫描提前停下（读满 `ARM_MAX`，或某次读取重试后仍失败）时，取它和停下的位置中较小的那个。比标记小的枪都已定锚或已关闭，而且永远不会变回去，所以一次读取失败不会丢掉这一遍已经读过的部分。标记存在 `STATE_DIR`；丢了只会让之后几遍从 1 号重扫（每遍最多 `ARM_MAX` 枪），结果不会错。

每个金库的做法和金库源码仓库里审过的 keeper 策略（`Play.s.sol STEP=sweep`）一致：先清队列再定锚，每笔开奖 3,000,000 gas，`SWEEP_MAX` 默认 500。这里改用 `cast` 实现，不需要 forge 和源码，另外加了两处：多个金库时先开奖、后定锚的两轮顺序，以及 `ARM_MAX` 上限。

**吞吐量：** 一笔交易开一枪，一笔拿到回执再发下一笔。每枪要读 4 次链、发 1 笔交易。`cast` 在 BNB Chain 上每 1.8 秒查一次回执：在本机对一个链 ID 为 56、0.45 秒出块的节点实测，从发出到拿到回执中位数 1.83 秒；Actions 上每次读取约 0.1 秒（从线上运行的日志量得）。合起来估计每枪 2.5 秒左右，**约每分钟 20 枪**，一个金库积压 500 枪（`SWEEP_MAX`）约 25 分钟清完。这是按实测的几部分估算的，没有在主网上整段量过。万一积压多到一枪一枪来不及在约 61 分钟的窗口内开完，可以手动一笔开一串：`settleFallback(k)` 会先把队列里排在 k 前面的枪依次开掉，再开 k，全在一笔交易里。gas 上限要够这一串（每枪的 gas 见下文「gas 开销」，每一枪中奖转账前还要剩 300,000），BNB Chain 单笔交易最多 16,777,216 gas。守护程序自己不这么做。

守护钱包**只付 gas**：它收不到任何奖金，也没有任何权限。它和定时服务、玩家、另一个守护程序同时运行都安全：交易被别人抢先，会回链上核对，确认已被别人开掉或定锚，就记为完成，不算失败。交易没拿到回执（`cast` 等超时，或节点收下交易后却报错）时，先盯链 30 秒，这一枪关了或锚定了就算完成，仍然没动才算失败。节点报 `nonce too low`（nonce 已用）也这样处理，它证明不了交易没发出去：节点返回 HTTP 429 或 503 时 `cast` 会把交易再发一次，负载均衡的节点也可能收下交易后仍然报错，所以用掉这个 nonce 的可能正是这笔交易自己。能证明交易根本没发出去的错误（`cast` 估算 gas 时调用失败或回滚；节点因余额不足、gas 太低直接拒收）不用等，立刻回链上核对；其中定锚交易的 gas 估算被金库以「已定锚」或「已结算」回滚的，说明别人已经抢先，直接记为被别人抢先，不再回链上读（落后的节点可能还显示这一枪超时没锚）。失败时日志写出原因：交易上了链但回滚的，用回执里的 revert 原因（`cast` 按交易所在的块重放得到）；没有的话，看它是否用光了 gas 上限；再没有，就按交易所在的块模拟同一调用，从不按之后的块模拟。开奖和定锚都这样。

**不打印 RPC 地址：** 地址里可能带 API key，所以 `keeper.sh` 的日志从不打印它；引用节点的报错时，也把其中的 RPC 地址、它的主机名，以及路径、查询串、用户名里 8 位以上的长串都换成 `<rpc>`，其他 URL 换成 `<url>`。

退出码：

- `0`：本遍没有失败（包括无事可做、被别人抢先，以及读不到守护钱包余额）。
- `1`：有失败：RPC 连不上或链不对，`STATE_DIR` 或临时文件建不了，RPC 读取重试后仍失败，交易没成功而这一枪仍然没关，或者标记写不进去。一个金库出错后，这一遍照样处理其他金库和另一轮，最后以 1 退出。
- `2`：配置错误（`CHAIN_ID`、`KEEPER_PK`、`DRY_RUN`、`FACTORY`、`SETTLE_GAS`、`SWEEP_MAX`、`ARM_MAX`、`LOW_BALANCE` 不合法，或没装 `cast`），什么都没发。
- `3`：本遍没有失败，但守护钱包余额低于 `LOW_BALANCE`。

余额低于 `LOW_BALANCE` 时一定打印充值提醒，退出码是 1 时也一样。只依赖 bash（3.2 及以上）和 Foundry 的 `cast`。

## 为什么必须跑

- **开奖窗口只有约 61 分钟。** 锚块定下后，它的哈希只在链上保存 8,191 个区块。2026-09-29 在 BNB Chain 上实测：区块 124,682,565 到 124,690,756 这 8,191 个区块用时 3,687 秒（约 61 分钟）。窗口内没人开奖，这一枪作废，一分不赔。
- **定时服务的开奖回调可能被压住。** 定时服务把请求成批执行。开奖回调和定锚回调在同一批执行时，锚块还没出，回调什么都不做。同一批里别的请求也可能耗光这一批的 gas，让开奖回调失败。执行过的回调（哪怕什么都没做）不会再来，失败的回调要等有人重试。任何人花一份服务费（56 上现在是 0.0002 BNB），就能故意制造这种情况。这时只能靠 `settleFallback`。
- **不能靠玩家自己的页面。** 界面上的「立即开奖」只有玩家开着页面时才会发出。玩家关掉页面，中奖的枪就没人开了。平台方不运行 keeper。守护程序不管页面开没开，都会在窗口内把奖金开给玩家。

## 运维责任

- **谁负责：** 项目方。**第一次发币之前**就要跑起来，之后一直跑，直到金库不再使用。
- **守护钱包：** 专门新建一个钱包，只放付 gas 用的 BNB。不要用部署钱包、dev 钱包或和金库有关的任何钱包。
- **gas 开销：** 定时服务正常时会自己开奖，守护程序多数时候无事可做，不花钱。需要它出手时，BNB Chain 测试网 fork 实测每笔 gas：1 发没中约 131,400，1 发中奖约 169,000，10 发中奖约 205,500，100 发（单枪上限）中奖 594,545，关闭一枪过期的 60,820，定锚一次 93,186。主网计价币的转账可能更贵，但每笔开奖都有 3,000,000 gas 上限：按 56 上现在的 gas 价 0.05 gwei，一笔最多 0.00015 BNB，实测最重的一笔约 0.00003 BNB。建议钱包里常备 **0.05 BNB**，最坏情况也够 300 多笔。
- **怎么充值：** 往守护钱包地址转 BNB。每次运行日志的第一行会打印这个地址（`keeper 0x…`），最后一行打印余额。
- **要盯什么：**
  - **失败提醒。** 某一遍失败时，那次运行会标红，日志里有对应的 warning，`FAILED` 那一行写了哪一枪、哪笔交易、什么原因。定时触发的运行失败时，GitHub 会给最后修改工作流里 `cron` 的账号发邮件；接力运行由工作流自己的 token 启动，GitHub 不一定为它发邮件，所以要定期看 Actions 页面（或在 GitHub → Settings → Notifications → Actions 打开 “Only notify for failed workflows”，至少能收到定时运行的失败）。
  - **钱包余额。** 余额低于 `LOW_BALANCE`（主网默认 0.005 BNB，测试网 0.001）时，这一遍照常跑完并打印充值提醒；没有别的失败时以退出码 3 结束（有失败时退出码是 1，提醒照样打印）。这次运行会标红（通知见上一条），充值后下一遍自动恢复。
- **手动运行：**
  - 在 GitHub 上：Actions → keeper → Run workflow。
  - 在本机：`CHAIN_ID=56 KEEPER_PK=0x… ./keeper.sh`。
  - 只看不发：`DRY_RUN=1 CHAIN_ID=56 ./keeper.sh`，不需要私钥。`DRY_RUN` 只认 `1`（只看不发）、`0` 或空（正常运行）；写成 `true`、`yes` 之类会作为配置错误以退出码 2 结束，什么都不发。
  - `cast` 通过命令行参数接收私钥，多人共用的机器上其他用户能在进程列表里看到，所以只在自己的机器上手动运行。
- **GitHub 定时靠不住，所以不单靠它。** 在这个仓库上实测：`*/5` 在五个多小时里只触发了两次，间隔超过三小时，远长于 61 分钟的窗口。所以每次运行自己每 5 分钟跑一遍、跑满 `minutes` 分钟（默认 55）后启动下一次运行（接力）；定时任务只用来在接力断掉时重新拉起。接力断掉（运行被取消、GitHub 故障）到下一次定时触发之间可能有几个小时没有守护程序，这段时间靠定时服务自己开奖和玩家页面的自动开奖。想更稳，可以在自己的服务器上用 cron 再跑一份，用另一个钱包。两份同时运行不会出错。

## 部署步骤

1. **仓库：** 用项目自己的 GitHub 账号新建一个**公开**仓库，把这个目录推到默认分支（定时任务只从默认分支运行）。
2. **守护钱包：** `cast wallet new` 生成新钱包。私钥只放进下一步的 Secret，不要存别处。往它的主网地址转约 0.05 BNB；要跑测试网，也往 97 转一些测试 BNB。
3. **Secrets：** 仓库 Settings → Secrets and variables → Actions → Secrets，新建 `KEEPER_PK`，值是守护钱包私钥。两条链共用这一个钱包。RPC 地址带 API key 时，也放在这里：`RPC_56` / `RPC_97`（同名的 Secret 优先于 Variable）。
4. **Variables（都可选）：** 同一页面的 Variables：
   - `RPC_56`：主网 RPC，默认 `https://bsc-mainnet.public.blastapi.io`。公共 RPC 有限流，建议换成自己的专用 RPC。**带 API key 的地址必须放 Secrets（上一步），不能放这里**：Actions 会在每一步日志的开头打印这一步的环境变量，只有 Secrets 会被打码。
   - `RPC_97`：测试网 RPC，默认 `https://bsc-testnet-rpc.publicnode.com`。同样，带 API key 的放 Secrets。
   - `RUN_97`：设成 `true` 才会同时跑测试网。
5. **启用 Actions：** 打开 Actions 标签页，如果提示工作流未启用，点启用。Settings → Actions → General 里要允许运行 `actions/checkout`、`actions/cache` 和 `foundry-rs/foundry-toolchain`（三个都按提交哈希固定了版本）。
6. **第一次运行：** Actions → keeper → Run workflow，看日志。主网发币前应该是 `0 vault(s)` 和 `nothing to do`；发币后工厂创建了金库，下一遍会自动发现它。
7. **通知：** 按上面「要盯什么」打开失败通知。

**定时保活：** 公开仓库连续 60 天没有活动，GitHub 会停掉定时任务。工作流里的 `keepalive` 任务每天 03:17（UTC）运行一次：最新提交已经满 30 天时，用工作流自带的 token 提交一个一行的 `.github/heartbeat` 文件。只有这个任务有 `contents: write` 权限。如果默认分支开了保护、不允许这个 token 推送，保活任务会失败并发邮件，需要放行。万一 Actions 页面显示工作流已停用，手动点 “Enable workflow”。

**状态：** 低水位标记存在 Actions cache 里。每次运行恢复最新的一份；跑完后，`state/` 里有标记文件时，用本次运行专属的 key 存一份新的（恢复没命中、这次也没写出标记时不存，免得一份空条目成了最新的、挡住之前那份）。每份只有几个字节，7 天没被读取的旧条目 GitHub 会自动清掉。cache 丢了只会让之后几遍从 1 号重扫。

**运行方式（接力）：** 每次运行每 5 分钟跑一遍（主网，`RUN_97` 为 `true` 时再跑测试网），跑满 `minutes` 分钟（默认 55）后，用工作流自己的 token 触发下一次运行（`workflow_dispatch`，只需要这一个 `actions: write` 权限），然后结束。某一遍失败不会打断接力，只让这次运行最后标红。手动运行时可以把 `relay` 设为 `false` 只跑这一次，`minutes` 设小一点做测试。

**同一时间只跑一次运行：** 一次运行还没结束，新来的运行（接力的下一次，或定时触发的）会排队等它，排队的只保留最新一次。接力正在跑时，定时触发的运行会被接力的下一次替换掉，所以不会出现两条接力。运行超过 120 分钟会被 GitHub 取消，正在跑的那一遍也会被中途打断；这时不交接也不保存标记，下一次定时触发会从上次保存的标记重新开始（已经发出的交易都在链上，重跑时会先回链上核对）。

## Actions 分钟额度

- **公开仓库：** GitHub 托管的标准 runner 免费，不限分钟数。这个仓库应该公开。仓库里没有任何秘密：私钥在 Secrets 里。`keeper.sh` 的日志里有守护钱包地址、金库地址和交易哈希（本来就在链上公开），没有 RPC 地址；但每一步日志开头打印的环境变量里有来自 Variables 或默认值的 RPC 地址，只有来自 Secrets 的会被打码。所以带 API key 的 RPC 地址只能放 Secrets（`RPC_56` / `RPC_97`）。
- **私有仓库：** 免费额度每月 2,000 分钟。接力运行让一个 runner 全天占用，一个月约 60 × 24 × 30 = 43,200 分钟，**任何套餐的额度都远远不够**。私有仓库只能改用自托管 runner，或者在自己的服务器上用 cron 跑 `keeper.sh`。

## 本地演练

`test/fork-drill.sh` 会在本地空闲端口起一个 BNB Chain 测试网的 anvil fork，所有交易只发到这个 fork，结束时关掉它。它模拟定时服务只定锚、不开奖，然后逐项检查：

- 队列为空、没有超时枪时，一遍什么都不发。
- 三枪可开奖（10、10、100 发）：先 dry run 只列出不发送，再从队首按顺序每枪一笔开掉，每笔 gas 上限 3,000,000，奖金全部到玩家钱包，守护钱包只付 gas。
- 开枪 6 小时没锚：先定锚（锚块正好是定锚交易所在块的下一块），下一遍开奖；低水位标记先停在这一枪，开完后前移。
- 再跑两遍：什么都不发。
- 30 枪、`SWEEP_MAX=20`：第一遍开 20 枪，第二遍开完剩下 10 枪，全程按队列顺序。
- 两枪锚块哈希已过期、排在一枪可开奖的前面：按顺序关闭，不赔付，3 笔交易，下一遍不再发送。
- 队首先被别人开掉；内存池真实抢跑（对手用 10 倍 gas 价格同块抢先）；两个守护程序同时运行。都不算失败，每枪只开一次。
- 一枪没锚、后面又开了 20 枪：6 小时后照样从低水位标记找到它并定锚。
- 锚块哈希读不到的真实失败：只发一笔，报出原因，退出码 1；哈希恢复后下一遍开掉。
- 余额不足退出 3，缺私钥退出 2，RPC 链不对或连不上退出 1。
- 超时扫描读到一半，某一枪的读取一直失败：退出 1，新标记停在这一枪，之前读过的几枪下一遍不再重读；余额低的提醒照样打印；节点报错里带的 RPC 地址和 key 在日志里都被遮住。`ARM_MAX=2`：一遍只读两枪，标记停在第三枪，下一遍接着读完。
- 节点让定锚交易的 gas 估算回滚：记为没发出去，立即判定，不盯链 30 秒，什么都没发，退出 1；节点给的 gas 估算太低：定锚交易用光 gas，日志写明 out of gas，汇总里记上这笔交易和这次失败，退出 1。下一遍正常定锚，再下一遍开奖。
- 开奖失败的原因来自交易所在的块：节点在最新块上模拟这笔调用必定报错（有对照检查），日志里仍是金库自己的原因（锚块哈希不可读）。
- 两个金库：金库 #1 的可开奖枪先开，之后才给金库 #0 的超时枪定锚（按 nonce 核对）。
- `DRY_RUN=true`、`DRY_RUN=yes` 退出 2，队首有一枪可开奖也什么都不发；`DRY_RUN` 为空时正常运行，把它开掉。
- `cast` 在标准错误输出上打印警告（nightly 版每次调用都会）：读取不受影响，照常开奖。
- 节点收下守护程序的开奖或定锚交易（交易真的上了链），却回 `nonce too low`，读链的节点还落后几秒：盯链后记为已完成（没拿到回执），不说没发出去，也不重发，退出 0。定锚交易的 gas 估算被金库以「已定锚」或「已结算」回滚（对手先定锚，或定锚后又开掉了），读链的节点还停在对手之前：记为被别人抢先，退出 0，什么都没发，低水位标记停在这一枪，读到最新状态的下一遍才前移。
- 所有日志里都没有私钥，也没有 RPC 地址或 key。

需要 anvil、cast、bc 和 python3。fork 执行交易时要从公共节点读还没见过的存储，anvil 遇到一次断线就放弃，交易会卡在 fork 的交易池里，测到的是网络而不是守护程序。所以 anvil 通过 `test/fork-relay.py` 读公共节点：每个请求用新连接，失败就重试。同一个脚本带上故障规则，放在守护程序和 fork 之间，扮演对某一种调用给出自己答复的节点，或读链落后的节点（上面读取失败、gas 估算、开奖失败原因、`nonce too low` 和估算被金库回滚几项）。最后一项检查确认没有哪一遍碰到 fork 上游错误。不设 `SHOOTER_PK` 时，用临时生成的钱包开枪，不需要任何私钥。`DRILL_ONLY="J K"` 只跑指定的几节（准备工作和最后的检查总会跑），`KEEPER_SH` 指定要测的守护程序（默认 `./keeper.sh`），`KEEPER_BASH` 指定运行它的 shell。

```
test/fork-drill.sh
```

---

## What it is

`keeper.sh` is the claw vaults' keeper. It runs one pass every 5 minutes on GitHub Actions (as a relay of runs, see "How it runs" below), over **every** vault the claw factory has made (a new vault is picked up automatically, with no configuration change), in two rounds: first every vault's settle queue, then every vault's overdue shots. Settling has a deadline and arming does not, so no vault's scan holds back another vault's settles.

1. **The settle queue, from its head.** While the head shot's anchor block is mined (status 4, ready) or its anchor's hash has left the history window (status 6, spent), it calls `settleFallback(head)`: one transaction per shot, strictly in queue order, each with an explicit gas limit of 3,000,000 (the vault reverts a settlement that lacks the gas to deliver a win, so a node's bare estimate is never used). A ready shot pays the amount fixed when it was anchored, straight to its shooter. When the quote token refuses that transfer (or the shooter's side does), the shot is settled all the same and the prize stays in the vault as owed to the shooter (an `Owed` event); the shooter collects it with `withdrawOwed(to)`, and the keeper's log says so for that shot. A spent shot is closed and pays nothing. At most `SWEEP_MAX` (500) shots per vault per pass; the next pass goes on.
2. **Overdue shots.** From the vault's low-water mark towards `nextShotId`, reading at most `ARM_MAX` (500) shots per vault per pass, every shot still without an anchor 6 hours after its fire (status 2) gets `armFallback`, and a later pass settles it once the anchor is mined. The new mark is the first id that had no anchor in this pass, or, when the scan stopped early (`ARM_MAX` reached, or a read that kept failing), the id where it stopped if that is lower. Every shot below the mark is anchored or closed, for good, so a failed read never loses what the pass had already read. The marks live in `STATE_DIR`. A lost mark only makes the next passes rescan from shot 1, `ARM_MAX` shots a pass.

For each vault this follows the reviewed keeper policy of the vault's source repository (`Play.s.sol STEP=sweep`): the queue first, then the arms, 3,000,000 gas per settle, `SWEEP_MAX` 500 by default. It is rebuilt on `cast`, so it needs neither forge nor the sources, and it adds two things: the two rounds across vaults (every settle before any arm) and the `ARM_MAX` cap.

**Throughput:** one shot per transaction, each sent once the previous one has its receipt. A shot takes four reads and one transaction. On BNB Chain `cast` polls for a receipt every 1.8 s: measured on this machine against a node with chain id 56 and 0.45 s blocks, sending to receipt took 1.83 s at the median; a read takes about 0.1 s on the Actions runner (measured from the live runs' logs). Together that is about 2.5 s a shot, **about 20 shots a minute**, so a backlog of 500 shots (`SWEEP_MAX`) in one vault clears in about 25 minutes. This is an estimate from measured parts, not measured end to end on mainnet. Should a backlog ever be too large to settle one by one inside the 61-minute window, one transaction can settle a run of shots by hand: `settleFallback(k)` first settles every shot ahead of k in the queue, then k. Its gas limit must cover the whole run (per-shot gas under "Gas" below, plus 300,000 left before each win's transfer), and a BNB Chain transaction may carry at most 16,777,216 gas. The keeper itself never does this.

The keeper wallet **pays gas and nothing else**: it receives no winnings and holds no powers. It is safe to run alongside the Trigger Service, players and other keepers: when a transaction loses a race, the keeper checks the chain, and a shot someone else settled or armed first counts as done, not as a failure. A transaction that comes back without a receipt (cast gave up waiting, or the node took it and answered with an error) is judged the same way after 30 s of watching the chain: only a shot still open then is a failure. So is `nonce too low`, which does not prove the transaction never left: cast sends a transaction again when the node answers HTTP 429 or 503, and a load-balanced node may take a transaction and still answer with an error, so the used nonce can be the transaction's own. An error that proves the transaction never left (cast's gas estimate failed or reverted; the node refused it outright for funds or too little gas) is judged at once, without the wait; an arm whose gas estimate the vault reverts as already anchored or already settled lost to someone else, and counts so without another read of the chain (a node that lags behind may still show the shot overdue). Every failure says why in the log: for a transaction that was mined and reverted, the revert reason in its receipt (cast replays it as of its own block); failing that, whether it used all of its gas limit; failing that, the same call simulated as of that block, never a later one. Settles and arms alike.

**The RPC URL is never printed:** a URL can carry an API key, so the keeper's log never shows it, and a node error it quotes has the RPC URL, its host, and every token of 8 or more characters of its path, query or user part replaced by `<rpc>`, and any other URL by `<url>`.

Exit codes:

- `0`: the pass completed without a failure (including nothing to do, races lost to others, and a keeper balance that could not be read).
- `1`: a failure: the RPC unreachable or serving another chain, `STATE_DIR` or a temporary file that cannot be created, an RPC read that kept failing, a transaction that did not go through while its shot stayed open, or a mark that could not be written. Past a failure in one vault the pass goes on with the other vaults and the other round, then exits 1.
- `2`: configuration error (`CHAIN_ID`, `KEEPER_PK`, `DRY_RUN`, `FACTORY`, `SETTLE_GAS`, `SWEEP_MAX`, `ARM_MAX`, `LOW_BALANCE`, or `cast` missing); nothing was sent.
- `3`: no failure, but the keeper balance is below `LOW_BALANCE`.

A balance below `LOW_BALANCE` always prints a top-up warning, also when the exit code is 1. It needs only bash (3.2 or later) and Foundry's `cast`.

## Why it must run

- **The settle window is about 61 minutes.** Once a shot's anchor is fixed, the anchor's hash is served for 8,191 blocks. Measured on BNB Chain on 2026-09-29, the 8,191 blocks from 124,682,565 to 124,690,756 took 3,687 s (about 61 minutes). A shot nobody settles in that window is spent and pays nothing.
- **The service's settle callback can be held back.** The Trigger Service runs requests in batches. When a shot's settle callback runs in the same batch as its anchor callback, the anchor block does not exist yet and the callback does nothing. Another request in the same batch can also use up the batch's gas and make the settle callback fail. A callback that ran, even one that did nothing, is not delivered again, and a failed one waits for someone to retry it. Anyone can cause this on purpose for one service fee (0.0002 BNB on 56 today). Then only `settleFallback` settles the shot.
- **A winner cannot depend on the player's own page.** The UI's "settle now" only goes out while the player's page is open. Once the tab is closed, nobody settles that shot. The platform does not run a keeper. This keeper settles in the window whether the page is open or not.

## Operations

- **Who is responsible:** the project team, **from before the first launch**, for as long as the vaults are in use.
- **Keeper wallet:** a new wallet that holds only BNB for gas. Never the deployer, the dev wallet or any wallet tied to the vaults.
- **Gas:** while the Trigger Service works, the keeper has nothing to do and spends nothing. When it acts, measured per transaction on a BNB Chain testnet fork: one bullet, no win, about 131,400 gas; one bullet, a win, about 169,000; ten bullets, a win, about 205,500; 100 bullets (the most a shot may carry), a win, 594,545; closing a spent shot 60,820; one arm 93,186. The mainnet quote's transfer may cost more, but every settle carries a 3,000,000 gas limit: at today's 0.05 gwei on 56, a transaction costs at most 0.00015 BNB, and the heaviest one measured about 0.00003 BNB. Keep about **0.05 BNB** in the wallet: more than 300 transactions even at the limit.
- **Topping up:** send BNB to the keeper address. Every run prints it on its first line (`keeper 0x…`) and the balance on its last.
- **What to watch:**
  - **Failure alerts.** A pass that fails marks its run red, with a warning in the log; the `FAILED` line names the shot, the transaction and the reason. GitHub e-mails a failed scheduled run to the account that last changed the workflow's `cron` lines, but a relay run is started by the workflow's own token and may not be e-mailed about, so check the Actions page regularly (turning on "Only notify for failed workflows" under GitHub → Settings → Notifications → Actions still covers the scheduled runs).
  - **The wallet balance.** Below `LOW_BALANCE` (default 0.005 BNB on 56, 0.001 on 97), the pass still completes and prints a top-up warning; without another failure it exits with code 3 (with one, the code is 1 and the warning is printed all the same). The run shows as failed (see the alerts above); after a top-up the next pass is green again.
- **Running it by hand:**
  - On GitHub: Actions → keeper → Run workflow.
  - Locally: `CHAIN_ID=56 KEEPER_PK=0x… ./keeper.sh`.
  - To see what it would do without sending anything: `DRY_RUN=1 CHAIN_ID=56 ./keeper.sh` (no key needed). `DRY_RUN` takes `1` (read only), or `0` or empty (a normal pass); anything else, such as `true` or `yes`, is a configuration error: exit 2, nothing sent.
  - `cast` takes the key as a command-line argument, which other users of a shared machine can see in the process list. Run it by hand only on your own machine.
- **GitHub's schedule is not relied on.** Measured on this repository, the `*/5` schedule fired twice in five hours, with a gap of more than three hours, far longer than the 61-minute window. So each run passes every 5 minutes itself for `minutes` minutes (55 by default) and then starts the next run (a relay); the schedule only restarts the relay if it ever stops. Between a stopped relay (a cancelled run, a GitHub outage) and the next scheduled run there can be hours without a keeper; the Trigger Service's own settle and the players' pages cover that time. For more margin, run a second copy from your own server's cron with a different wallet. Two copies at once are safe.

## Setup

1. **Repository:** with the project's own GitHub account, create a **public** repository and push this directory to its default branch (schedules only run from the default branch).
2. **Keeper wallet:** `cast wallet new`. Put the key only into the secret of the next step. Send the address about 0.05 BNB on 56, and some test BNB on 97 if you run the testnet too.
3. **Secrets:** under Settings → Secrets and variables → Actions → Secrets, create `KEEPER_PK` with the keeper wallet's key. Both chains use this one wallet. An RPC URL with an API key goes here too, as `RPC_56` / `RPC_97` (a secret wins over a variable of the same name).
4. **Variables (all optional),** on the same page:
   - `RPC_56`: the mainnet RPC, default `https://bsc-mainnet.public.blastapi.io`. Public RPCs rate-limit, so a dedicated one is better. **A URL with an API key must be a secret (the step above), never a variable:** Actions prints each step's environment at the top of its log and masks only secrets there.
   - `RPC_97`: the testnet RPC, default `https://bsc-testnet-rpc.publicnode.com`. The same goes for a keyed URL here.
   - `RUN_97`: set to `true` to run the testnet as well.
5. **Enable Actions:** open the Actions tab and enable workflows if GitHub asks. Under Settings → Actions → General, allow `actions/checkout`, `actions/cache` and `foundry-rs/foundry-toolchain` (all three pinned to a commit hash).
6. **First run:** Actions → keeper → Run workflow, and read the log. Before the mainnet launch it says `0 vault(s)` and `nothing to do`; once the factory has made a vault, the next pass finds it.
7. **Notifications:** turn on failure notifications as described under "What to watch".

**Keep-alive:** GitHub turns off the schedule of a public repository after 60 days without activity. The workflow's `keepalive` job runs daily at 03:17 UTC: when the newest commit is 30 days old or more, it commits a one-line `.github/heartbeat` file with the workflow's own token. It is the only job with `contents: write`. If the default branch is protected against that token's pushes, the keep-alive job fails and e-mails you; allow it. If the Actions page ever shows the workflow as disabled, press "Enable workflow".

**State:** the low-water marks live in the Actions cache. Each run restores the newest entry and, when `state/` then holds a mark file, saves a new one under a key of its own (after a restore that missed and passes that wrote no mark it saves nothing, so an empty entry never becomes the newest and hides the older good one). Each entry is a few bytes, and GitHub drops entries nobody has read for 7 days. A lost cache only makes the next passes rescan from shot 1.

**How it runs (a relay):** each run passes every 5 minutes (mainnet, and testnet when `RUN_97` is `true`) for `minutes` minutes (55 by default), then starts the next run with the workflow's own token (`workflow_dispatch`, the one `actions: write` permission it needs) and ends. A failed pass does not stop the relay; it only marks that run red at the end. Run it by hand with `relay` set to `false` for a single run, and a small `minutes` for a test.

**One run at a time:** a run that arrives while another is going (the relay's next one, or a scheduled one) waits for it, and only the newest waiting run is kept. While the relay is going, a scheduled run is replaced by the relay's next one, so there are never two relays. GitHub cancels a run that passes 120 minutes, cutting off the pass in progress; such a run hands over nothing and saves no marks, and the next scheduled run starts again from the last saved marks (whatever was sent is on the chain, and the next pass checks the chain first).

## Actions minutes

- **Public repository:** GitHub-hosted standard runners are free and unmetered, so this repository should be public. It holds no secret: the key lives in Secrets. The keeper's own log shows the keeper address, vault addresses and transaction hashes (public on-chain anyway), and no RPC URL; but the environment printed at the top of each step's log shows an RPC URL that comes from a variable or the default, and masks only one from a secret. So an RPC URL with an API key belongs in the secrets `RPC_56` / `RPC_97`.
- **Private repository:** the free plan includes 2,000 minutes a month. The relay keeps one runner busy all day, about 60 × 24 × 30 = 43,200 minutes a month, **far beyond any plan's allowance**. A private repository needs a self-hosted runner, or `keeper.sh` run from your own server's cron.

## Fork drill

`test/fork-drill.sh` starts an anvil fork of BNB Chain testnet (97) on a free local port, sends every transaction to that fork only, and stops it at the end. It plays a Trigger Service that anchors shots but never settles them, and checks that:

- With an empty queue and nothing overdue, a pass sends nothing.
- Three ready shots (10, 10 and 100 bullets): a dry run first lists them and sends nothing; then the keeper settles them from the head in queue order, one transaction each with a 3,000,000 gas limit; every win reaches the shooter's wallet, and the keeper only pays gas.
- A shot with no anchor 6 hours after its fire is armed (its anchor is exactly the block after the arm's own block), then settled on the next pass; the low-water mark holds at it, then moves past it.
- Two more passes send nothing.
- Thirty shots with `SWEEP_MAX=20`: the first pass settles 20, the second the other 10, all in queue order.
- Two shots whose anchor hash expired, ahead of a ready one: closed in order, paying nothing, in three transactions; the next pass sends nothing.
- The head settled by someone else first; a real mempool race (a rival settles the same shot first, in the same block, at 10x the gas price); two keepers at once. None counts as a failure, and every shot is settled once.
- A shot left without an anchor, with twenty shots fired after it, is still found from the low-water mark and armed 6 hours on.
- A real failure (an anchor hash the history contract does not serve): one transaction, the reason in the log, exit 1; once the hash is served, the next pass settles it.
- A low balance exits 3, a missing key 2, an RPC of the wrong chain or no RPC at all 1.
- A read that keeps failing part-way through the overdue scan: exit 1, the new mark is that shot, so the shots read before it are not read again; the low-balance warning is printed all the same; the node's error quoted the RPC URL and its key, and the log shows both masked. With `ARM_MAX=2` a pass reads two shots and leaves the mark at the third; the next pass reads on.
- An arm whose gas estimate the node reverts: counted as never sent and judged at once, with no 30 s watch; nothing sent, exit 1. An estimate too low: the arm runs out of gas, the log says so, the summary counts that transaction and the failure, exit 1. The next pass arms the shot and the one after settles it.
- A failed settle's reason comes from its own block: through a node whose simulation of that call at the latest block always fails (checked by a control), the log still gives the vault's own reason (anchor hash unavailable).
- Two vaults: vault #1's ready shot is settled before vault #0's overdue shot is armed (checked by nonce).
- `DRY_RUN=true` and `DRY_RUN=yes` exit 2 and send nothing, with a ready shot at the head; an empty `DRY_RUN` is a normal pass and settles it.
- A warning cast prints on its standard error (a nightly build does, on every call) spoils no read, and the pass settles as usual.
- A node that takes the keeper's settle or arm (it really lands on the fork) and still answers `nonce too low`, with a reader a few seconds behind: the keeper watches the chain and counts it done without a receipt, never as not sent, and sends nothing twice; exit 0. An arm whose gas estimate the vault reverts as already anchored or already settled (a rival armed it, or armed and settled it, first), through a reader still behind the rival: a race lost to someone else, exit 0, nothing sent, and the low-water mark stays at that shot until a pass reads the chain as it is.
- No private key, RPC URL or key appears in any log.

It needs anvil, cast, bc and python3. A fork reads every storage slot it has not seen yet from the public endpoint while it executes a transaction, and anvil gives up on the first dropped connection: the transaction then sticks in the fork's pool, and the drill would measure the network, not the keeper. So anvil reads the public endpoint through `test/fork-relay.py`, which opens a fresh connection for each request and retries a failed one. The same script with a fault rule, between the keeper and the fork, plays a node that answers one kind of call its own way, or a reader that lags behind the chain (the failed read, the gas estimates, the settle's reason, the `nonce too low` answers and the refused arms above). A last check confirms that no pass met a fork upstream error. Without `SHOOTER_PK`, the shots are fired from a fresh throwaway wallet, so no key is needed. `DRILL_ONLY="J K"` runs only the sections it names (the setup and the closing checks always run), `KEEPER_SH` names the keeper under test (default `./keeper.sh`) and `KEEPER_BASH` the shell that runs it.

```
test/fork-drill.sh
```
