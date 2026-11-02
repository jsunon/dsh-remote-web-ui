# dsh-remote-web-ui · 独立分支

从 [`zhu1090093659/dsh-web`](https://github.com/zhu1090093659/dsh-web) 单体仓中分离出来的
`@linxin666/dsh-remote-web-ui` —— DeepSeek Harness (DSH) Web GUI 的**扫码配对浏览器远程控制**插件。

> **上游状态**：该包在上游已于 `v0.4.13` 从聚合包 `@linxin666/dsh-web-all` 中退役，
> 由原生手机 App 方案 `@linxin666/dsh-remote-bridge` 承接，并计划在后续版本正式删除。
> 本仓保留其完整实现，用于继续维护或二次开发。

## 分离说明

| 项目 | 内容 |
|---|---|
| 包名 | `@linxin666/dsh-remote-web-ui` |
| 源位置 | `dsh-web` 仓 → `packages/dsh-remote-web-ui` |
| 源版本 | `v0.4.13`（tag `v0.4.13`） |
| 本仓路径 | `packages/dsh-remote-web-ui`（保持原路径，未改动源码） |

为保持**零源码改动**，仓库结构保留了上游的两层形态：

```
.
├── package.json                 # 工作区根，只放构建工具链
├── pnpm-workspace.yaml          # 单包工作区 + 构建脚本放行 + 预发布门禁豁免
├── shared/                      # 上游根部的构建辅助（原样拷贝）
│   ├── tsdown.client.ts         # 客户端 bundle 预设，被 tsdown 配置引用
│   └── web-platform.ts          # 平台模块表，前缀导入
└── packages/
    └── dsh-remote-web-ui/       # 插件本体，与上游 v0.4.13 逐字节一致
```

保留 `shared/` 的原因：包内 `tsdown.config.ts` 与 `tsdown.prepare.config.ts` 都以
`../../shared/tsdown.client.ts` 引用它，且该辅助文件用 `new URL('..', import.meta.url)`
把自身上一级当作仓库根（用于把 CSS 虚拟 id 映射回仓内相对路径）。层级一动，这两处假设都会失效。

## 依赖关系

包本身**没有任何 `workspace:*` 依赖**，这是它能被干净分离的前提：

- **运行时依赖**：`@deepseek-ai/schemastery`、`cloudflared`、`clsx`、`qrcode.react`、`yaml`、`zod`
- **peer 依赖**：`@deepseek-ai/dsh >=0.2.1-rc.3`、`react`、`react-dom`
- **开发依赖**：DSH SDK 的 `@deepseek-ai/*` 预发布包（用于类型解析）+ `tsdown`、`typescript`、`vitest`、`jsdom`

SDK 类型全部从 npm 上的 `@deepseek-ai/*` 解析，**不依赖宿主源码检出**——包内 `tsconfig.json`
的注释对此有明确约定。

## 与上游的差异（构建层 3 处，不触碰插件源码）

1. **`shared/` 被复制进本仓**。上游它位于单体仓根部、被多个包共享；这里只搬运被本包
   `tsdown` 配置实际引用的两个文件，层级不变，因此 `../../shared/...` 的相对导入与
   `new URL('..', import.meta.url)` 的仓库根假设都保持有效。
2. **根 `package.json` 增加 `simple-icons@^13.21.0` 开发依赖**。上游 SDK 的
   `@deepseek-ai/dsh-client-ui-primitives` 在产物里以具名导入引用 `simple-icons`
   （`siGoogle` 等），却未在自己的 `dependencies` 里声明它——在单体仓里靠提升侥幸可用，
   分离后会变成 `Cannot find package 'simple-icons'`，导致 5 个测试文件失败。
   这里显式补在根，属于**依赖声明补齐**，不是源码修改。版本选 `13.x` 是因为
   `simple-icons` 从 14 起取消了逐图标具名导出，14/15 无法满足该导入形式。
3. **新增 `pnpm-lock.yaml`**。上游的锁文件覆盖全仓数百个包，不适用于单包工作区；
   本仓的锁文件由本工作区独立安装生成。

除上述三项，`packages/dsh-remote-web-ui/` 下的文件与上游 `v0.4.13` 一致
（`cordis.patch.yml`、`locale/`、`assets/`、`icon.svg` 全部原样保留），
**唯一的源码改动**见下一节。

## 源码改动（1 处）：修复中继双重压缩导致整页乱码

### 现象

手机通过公网中继地址（`https://<id>.dsh-market.com`）扫码打开时，页面正常返回 200，
但渲染出来是满屏乱码符号；用局域网地址访问则正常。

### 原因

公网中继的 worker 会按**客户端协商到的算法**（`zstd` / `br`）对响应体再压一层，
但把 origin 自己那份 `Content-Encoding` 头原样透传。于是手机收到的是
「头说 `zstd`、正文其实是 gzip」的响应，解码器按 zstd 去解 gzip 字节，必然失败。

实测同一 URL 声明不同 `Accept-Encoding` 的表现：

| 客户端声明 | 响应头 | 正文实际 | 结果 |
|---|---|---|---|
| `gzip, deflate, br, zstd` | `zstd` | 双层压缩 | 乱码 |
| `gzip, deflate, br` | `br` | 双层压缩 | 乱码 |
| `gzip` | `gzip` | gzip | 正常 |

属上游已知缺陷（`zhu1090093659/dsh-web` 的 #1998–#2001），作者已声明该插件不再维护，
不会再修，故在本仓就地修复。

### 修法

`src/relay-bridge-connector.ts` 的 `bridgeUpstreamHeaders()` 不再转发客户端的
`accept-encoding`，改为强制 `identity`：

```ts
for (const [name, value] of headerPairs(frameHeaders)) {
  if (BRIDGE_HOP_BY_HOP.has(name.toLowerCase())) continue
  if (name.toLowerCase() === 'accept-encoding') continue
  headers[name] = value
}
headers.host = host
headers['accept-encoding'] = 'identity'
```

这样本机 origin 返回明文，压缩只在边缘做一次、头也由边缘自己写，天然一致。
`tests/relay-bridge-connector.spec.ts` 同步更新了断言，并新增一条用例锁定该行为。

### 验证

修复后经公网中继实测，四种声明全部一致（按正文魔数判定）：

| 声明 | 响应头 | 正文魔数 | 结论 |
|---|---|---|---|
| `gzip, deflate, br, zstd` | `zstd` | `28 b5 2f fd` | 一致 |
| `br` | `br` | 非 gzip / zstd | 一致 |
| `gzip` | `gzip` | `1f 8b 08 00` | 一致 |
| `identity` | 无 | `<!doctype html>` | 明文 |

> 验证时注意：Windows 自带的 `curl` 不支持 zstd/br 解压，用 `--compressed` 会得到空响应，
> 看起来像服务故障，其实要按魔数判断。

## 使用

```bash
# 需要 Node ^22.19.0 || >=24，以及 pnpm 11
corepack enable pnpm

pnpm install
pnpm build        # tsc -b && tsdown，产物落在 packages/dsh-remote-web-ui/lib
pnpm test         # vitest
pnpm typecheck
```

装进 DSH profile：

```bash
dsh plugin --profile <profile> add link:$(pwd)/packages/dsh-remote-web-ui
```

或直接用 npm 上已发布的版本：

```bash
dsh plugin --profile <profile> add @linxin666/dsh-remote-web-ui@0.4.13
```

### 已验证

在 Node 22 / pnpm 11.7.0 下：`pnpm build` 成功产出 `lib/index.js`（约 317 KB）与
`lib/client.js`（约 286 KB）；`pnpm test` 600 个用例通过（补上 `simple-icons` 之前，
有 5 个测试文件因 `Cannot find package` 失败）。

### 与 `dsh-remote-bridge` 并存的风险

两者按 profile 共用**同一个中继身份**。若同时启用中继，会竞争 Durable Object 会合点；
新桥以 `relay=false` 挂载时还会主动撤销该身份的注册行并释放租约。二者只能启用其一。

## 许可

Apache-2.0，见 [LICENSE](./LICENSE)。原始版权归上游作者所有。
