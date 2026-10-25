# Regina Sports 通信协议 v1

三段链路：

```
Regina 手柄 ──BLE──┐
手机网页   ──WSS──┤──▶ regina-hub ──UDP──▶ Godot 游戏
模拟手柄   ──WS───┘                ◀──UDP──
```

- 所有二进制字段都是**小端**。
- **姿态融合、零偏校准、一键归零都在 hub 里做**。手柄只上传带时间戳的原始传感器数据，这样 Regina 和手机共用同一套算法，手感一致；调参也不用重新烧录固件。时间戳由设备打，所以积分不受 BLE 或 Wi-Fi 延迟抖动的影响。

## 1. 统一坐标系（hub 输出给游戏的）

和 Godot 一致，右手坐标系：

| 轴 | 手柄本体坐标（body） | 世界坐标（world） |
|---|---|---|
| +X | 手柄右侧 | 右 |
| +Y | 手柄上方（屏幕朝向） | 上（与重力相反） |
| −Z | 手柄指向的前方（顶端） | 归零时手柄指向的方向 |

“像电视遥控器一样拿着，屏幕朝上，顶端指向电视”就是**零姿态**（四元数为单位四元数）。

各来源的原始坐标都在 hub 里换算到这个坐标系，换算表在 `hub/regina_hub/frames.py`。Regina 的芯片安装方向如果和默认假设不一致，只需要改 `hub/config.json` 里的 `regina_axis_map`。

## 2. Regina ⇄ hub（BLE GATT）

设备名：`Regina-XXXX`（XXXX 是蓝牙 MAC 地址的最后 2 个字节）。服务 UUID 放在广播包里，设备名放在扫描响应里。

| 名称 | UUID | 属性 |
|---|---|---|
| 服务 | `5253a000-6a2e-4c1f-9b7e-726567696e61` | |
| IMU | `5253a001-6a2e-4c1f-9b7e-726567696e61` | notify |
| 输入 | `5253a002-6a2e-4c1f-9b7e-726567696e61` | read, notify |
| 状态 | `5253a003-6a2e-4c1f-9b7e-726567696e61` | read, notify |
| 指令 | `5253a004-6a2e-4c1f-9b7e-726567696e61` | write, write without response |

连接后手柄会主动申请 MTU 247，以及 7.5–15 ms 的连接间隔。

### 2.1 IMU 包（手柄 → hub）：200 Hz 采样，每 4 个样本打成一个包

| 偏移 | 类型 | 含义 |
|---|---|---|
| 0 | u8 | 类型 = `0x01` |
| 1 | u8 | 序号，每个包加 1，用来发现丢包 |
| 2 | u8 | 样本数 n |
| 3 | u8 | 量程：bit0–1 为加速度（0=±2g，1=±4g，2=±8g，3=±16g），bit2–4 为陀螺仪（0=±2000，1=±1000，2=±500，3=±250，4=±125 °/s） |
| 4 | u32 | 第一个样本的时间戳（µs，设备时钟，会回绕） |
| 8 | n × 14 字节 | 样本 |

每个样本：`u16 dt_us`（距上一个样本的时间，第一个样本为 0）、`i16 ax, ay, az`、`i16 gx, gy, gz`，都是芯片坐标系下的原始 LSB 值。

### 2.2 输入包（手柄 → hub）：变化时立即发送，另外每秒发 1 次心跳

| 偏移 | 类型 | 含义 |
|---|---|---|
| 0 | u8 | 类型 = `0x02` |
| 1 | u8 | 按键位：bit0=A，bit1=B，bit2=C，bit3=D |
| 2 | i16 | 小旋钮累计格数 |
| 4 | i16 | 大旋钮累计格数 |
| 6 | u32 | 时间戳（µs） |

### 2.3 状态包（手柄 → hub）：每 5 秒发送一次，变化时也发送

| 偏移 | 类型 | 含义 |
|---|---|---|
| 0 | u8 | 类型 = `0x03` |
| 1 | u8 | 电量百分比，255 表示未知 |
| 2 | u8 | 标志位：bit0=正在充电，bit1=IMU 正常，bit2=IMU 用的是数据就绪中断（否则是轮询） |
| 3 | u8 | 固件主版本号 |
| 4 | u8 | 固件次版本号 |
| 5 | u8 | 当前玩家编号（0 表示未分配） |

### 2.4 指令（hub → 手柄）

第一个字节是操作码：

| 操作码 | 负载 | 作用 |
|---|---|---|
| `0x01` | u8 玩家编号 | 设置玩家编号 |
| `0x04` | u16 频率 Hz，u16 时长 ms | 蜂鸣器响一声（固件 0.2 起默认静音，见 `board.h` 的 `BUZZER_ENABLED`） |
| `0x05` | u16 时长 ms | 震动（预留，目前固件不执行） |
| `0x06` | u8 旋转 0–3 | 屏幕方向（LovyanGFX 约定，1/3 为竖屏）。hub 在连接时按 `config.json` 的 `regina_screen_rotation` 下发，固件存进 NVS（固件 0.2 起） |
| `0x10` | 界面 TLV（见 2.5） | 更新 OLED 界面 |

### 2.5 界面 TLV（OLED 128×64）

格式是 `操作码 0x10` 后面接若干个 `tag u8, len u8, data[len]`。没有出现的字段保持不变；字符串长度为 0 表示清空该字段。**P0 阶段只支持 ASCII 字符**。

| tag | 数据 | 含义 |
|---|---|---|
| `0x00` | 无 | 先清空整个界面（必须放在最前面） |
| `0x01` | 字符串 | 顶栏标题 |
| `0x02` | 字符串 | 主文字（大字） |
| `0x03` | 字符串 | 副文字（小字） |
| `0x04` | u8 百分比 + 字符串标签 | 进度条；百分比为 255 表示隐藏 |
| `0x05`–`0x08` | 字符串 | A / B / C / D 键的功能提示 |
| `0x09` | u16 时长 ms + 字符串 | 弹出提示（toast） |

竖屏（默认，64×128）实际能显示的长度：标题 10 字符；主文字 3 字符以内用最大字号，7 字符以内用中字号，最多 10 字符；副文字 10 字符；按键提示 8 字符；toast 7 字符以内用大字，最多两行、每行 10 字符。横屏下标题 14 字符、按键提示 9 字符。

## 3. 手机网页 / 模拟手柄 ⇄ hub（WebSocket，JSON）

- 手机：`wss://<电脑局域网 IP>:47843/ws`，扫码页面地址是 `https://<电脑局域网 IP>:47843/#k=<本次启动令牌>`
- 模拟手柄：`ws://127.0.0.1:47802/ws`，页面地址是 `http://127.0.0.1:47802/sim`

每次启动 hub 都生成新的随机配对令牌（256 bit）。游戏中的二维码 URL 通过 fragment `#k` 携带它；fragment 不随 HTTP 请求发送，客户端只在 WebSocket 的 `hello.token` 中提交。不要分享二维码或完整 URL。手机删掉 `#k`、使用旧启动的令牌或仅伪造已配对的 `client_id` 均不能加入；有效令牌随同一页面的重连继续提交。令牌不存入 localStorage，也不打印到日志或终端二维码中。

每个 WebSocket 握手必须带与实际监听地址、端口及协议相同的 `Origin`；缺失、`null`、跨源或重复 Origin 返回 403。Host 只接受实际监听 IP（回环监听也接受 `localhost`），不信任任意 DNS 名称或代理转发头。手机 HTTPS 监听只开放 `/`、`/static/*`、`/ws`，`/sim` 和 `/api/*` 不在该监听上提供。

本机 HTTP 监听还要求客户端来自回环地址。模拟器从同源的 `GET /api/pairing` 获取 `{ "token": "..." }`；该接口不允许 CORS、禁止缓存，并校验请求的 Host 和可选 Origin。原有 `/api/status`、`/api/qr` 同样仅限本机。原生测试客户端也必须从本机取得令牌并显式设置正确 Origin，不能绕过配对。无效 `hello` 在分配控制器 ID 或玩家槽前以 WebSocket 1008 关闭。

`--https-host`（或配置 `https_host`）可将手机监听绑定到指定网卡，默认 `0.0.0.0`。证书只要求覆盖选用的手机 IP 与本机回环名称；无关网卡变化不重签，新增选用 IP 时保留私钥并扩展 SAN。重签后浏览器仍可能要求重新信任。

客户端 → hub：

```jsonc
{"t":"hello","kind":"phone","name":"iPhone","client_id":"随机持久 ID","profile_name":"Example Player","token":"从本次二维码或本机接口取得的令牌"}  // kind 取 phone 或 sim；name 是设备名，hub 会去掉控制字符、截断到 32 字符
{"t":"profile","name":"Example Player"} // 可选：修改玩家昵称，去控制字符、首尾空格，最多 20 字符
{"t":"m","frame":"device","s":[[ts_ms, gx,gy,gz, ax,ay,az], ...]}
//  frame 为 device：手机坐标系（x 向右，y 指向屏幕顶端，z 垂直屏幕向外）
//  frame 为 canonical：已经是第 1 节的本体坐标系（模拟手柄用）
//  陀螺仪单位 rad/s；加速度单位 m/s²，含重力，静止时测到的是向上的 +g
{"t":"in","b":按键位,"d":[小旋钮,大旋钮],"an":[模拟量0,模拟量1]}
{"t":"st","battery":87,"charging":false}  // battery 可以为 null
{"t":"ping","c":123}                     // 保活/测延迟；c 任意，hub 在 pong 里原样带回
{"t":"recenter"}                          // 归零当前手柄（hub 按本连接的手柄 id 执行）
{"t":"calibrate"}                         // 重新校准当前手柄零偏
```

hub → 客户端：

```jsonc
{"t":"welcome","id":3,"player":2}
{"t":"error","reason":"hub full"}           // hello 被拒：控制器注册表已满，hub 随即以 1013 关闭连接
{"t":"pong","c":123}                        // 对 ping 的回复
{"t":"profile","name":"Example Player"} // 昵称修改确认；设备 name 与重连 ID 不变
{"t":"player","player":2}
{"t":"ui", ...与第 4 节 ui 对象相同...}
{"t":"beep","freq":2000,"ms":80}
{"t":"vibrate","pattern":[40,60,70],"ms":40}   // 开、停、开…（毫秒），ms 是第一段，给旧页面用
{"t":"event","name":"recentered"}
```

## 4. hub ⇄ 游戏（本机 UDP）

hub 发到 `127.0.0.1:47800`（游戏监听这个端口）；游戏发到 `127.0.0.1:47801`（hub 监听这个端口）。测试模式和 `--hub-port` 的端口规则见 [ARCHITECTURE.md](ARCHITECTURE.md) 第 4 节。

手柄 id 是 u8（出现在下面的二进制包和 JSON 的 `controller` 字段中）。hub 按设备标识分配 id（Regina 按 MAC 地址、手机按 `client_id`、模拟手柄按连接标识）：从 1 起递增，同一设备在 hub 的一次运行内断线重连后沿用原 id，id 不回收给其他设备。

### 4.1 hub → 游戏，二进制高频数据

**姿态样本 `S`**：

`u8 'S'(0x53), u8 版本=1, u8 手柄 id, u8 n`，后面跟 n 个样本，每个 60 字节：

| 类型 | 含义 |
|---|---|
| f64 | t，hub 时钟下的秒数（已经换算过设备时间戳） |
| f32 ×4 | 姿态四元数 x, y, z, w（本体 → 世界，已经应用归零） |
| f32 ×3 | 角速度，本体坐标，rad/s，已减去零偏 |
| f32 ×3 | 加速度，本体坐标，m/s²，含重力 |
| f32 ×3 | 线加速度，世界坐标，m/s²，已减去重力 |

**输入 `I`**：

`u8 'I'(0x49), u8 版本=1, u8 手柄 id, u8 按键位, i16 小旋钮, i16 大旋钮, f32 模拟量0, f32 模拟量1`，共 16 字节。

### 4.2 hub → 游戏，JSON 低频消息（第一个字节是 `{`）

```jsonc
{"type":"roster","controllers":[{"id":1,"kind":"regina","name":"Regina-3F2A","player":1,
  "connected":true,"battery":87,"charging":false,"calibrated":true,"calibrating":false,"stationary":true,
  "rate_hz":199.6,"loss":0.0}],
 "phone_url":"https://<电脑局域网IP>:47843/"}
// 条目还可能带来源相关的可选键：Regina（BLE）有 "mtu"、"fw"、"imu_ok"、"imu_irq"，随状态包更新。
// 手机 / 模拟手柄条目可带 profile_name（可选、纯文本、最多 20 字符），用于更新对应 P1–P4 档案。
{"type":"qr","url":"https://...","rows":["1110...","..."]}   // 二维码矩阵，1 为黑块
{"type":"event","controller":1,"name":"recentered"}
// name 可能是 connected / disconnected / recentered / calibrated / calibrate_failed / low_battery
```

### 4.3 游戏 → hub，JSON 指令

```jsonc
{"cmd":"hello"}                                    // 每 2 秒发一次，同时用作心跳
{"cmd":"set_player","controller":1,"player":2}
{"cmd":"recenter","controller":1}                  // controller 为 0 表示全部手柄
{"cmd":"calibrate","controller":1}
{"cmd":"beep","controller":1,"freq":2000,"ms":80}
{"cmd":"vibrate","controller":1,"ms":60}             // 震一下
{"cmd":"vibrate","controller":1,"pattern":[40,60,70]} // 开、停、开…（毫秒），最多 16 段、共 3 秒
{"cmd":"qr"}                                     // 请 hub 把当前二维码（type:"qr" 消息）补发给游戏
{"cmd":"ui","controller":1,"ui":{"clear":true,"title":"ARCHERY","main":"","sub":"",
  "bar":{"pct":75,"label":"POWER"},"legends":["DRAW","BACK","",""],
  "toast":{"ms":800,"text":"HIT!"}}}
```

## 5. 内置行为

- **一键归零**：任意手柄**长按 D 键 1 秒**，hub 就把它当前的指向设为正前方（只重置水平方向，俯仰和横滚保持真实值），然后弹出提示、响一声，并向游戏发送 `recentered` 事件。
- **自动零偏校准**：hub 检测到手柄静止约 0.5 秒后，持续修正陀螺仪零偏；刚连接时，第一次静止满 1 秒会完成初始校准，并发送 `calibrated` 事件。
- **玩家编号**：新手柄连接时，自动分配最小的空闲编号（1–4）。同一个手柄断线重连后会保留原来的编号（Regina 按 MAC 地址识别，手机按 `client_id` 识别）。
- **低电量**：电量低于 15% 且没在充电时，发送一次 `low_battery` 事件，并在手柄屏幕上弹出提示。
