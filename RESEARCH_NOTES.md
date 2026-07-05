# HONOR FRI-H76 风扇控制 — 研究过程归档笔记

> 这是完整研究过程的记录(含探索性/走过的弯路),供存档参考。
> 面向使用者的干净说明见 `README.md`;GitHub 仓库:
> https://github.com/sealeelike/Honor-FRI-H76-fan-controller-for-linux

## 目标

荣耀 MagicBook X 14 Pro 锐龙版 2023(集显,R7 16GB+512GB,**FRI-H76** / FRI-HXX,
Ryzen 7 7840HS + Radeon 780M)在 Linux 下让风扇可控,最终实现空闲时**完全停转(zero-RPM)**。

起点困境:BIOS(Insyde,锁定)无风扇选项;Linux 无 hwmon/pwm/thermal 暴露该风扇;
nbfc 无对应配置。唯一出路 = 直接操作 EC(嵌入式控制器)。

## 关键事实

- EC 扩展空间(`0x0Axx`)无法用 `ec_sys` 访问,必须走 DSDT 的 `RDER`/`WTER` 方法。
  - `RDER(offset16)` 读一字节;`WTER(offset16, val)` 写一字节。
  - 路径:`\_SB.PCI0.LPC0.EC0`。协议是 CMDB 命令字(读 0x80 / 写 0x81)。
- 通过 `acpi_call` 内核模块从用户态调用(`/proc/acpi/call`)。
- Secure Boot 开着,所以 `acpi_call` 需 MOK 密钥签名 + 登记。

## 大致研究过程(时间顺序)

1. **侦察阶段**:确认无 hwmon/pwm/thermal/nbfc 路径(`nbfc_recon.sh`);
   反编译 DSDT(`ec_decompile.sh` / `decompile_only.sh` → `DSDT.dsl`),
   提取出 RDER/WTER 及风扇相关方法(`wter_fan_extract.txt`)。
2. **搭桥阶段**:安装 acpi_call(`install_acpi_call.sh`);因 Secure Boot 需签名,
   用 MOK 密钥签名并登记模块(`sign_acpi_call.sh`),重启在蓝色界面 Enroll MOK。
   完成后 `/proc/acpi/call` 可用。
3. **只读验证**:`ec_read_test.sh` 确认 RDER 通路,读到真实转速(Fan0 ≈ 2527 RPM)。
4. **相关性扫描(核心方法)**:`ec_correlate.sh` / `ec_correlate2.sh` —— 在空闲/满载/
   冷却三阶段采样整个风扇寄存器区,并同时读 hwmon 真实温度做交叉比对。凡是随负载
   变化、又不等于任何温度值的寄存器,即风扇相关寄存器。由此锁定:
   - `0x0A00/0x0A01` = Fan0 RPM 回读;`0x0A04` = RPM/100 回读。
5. **写测试(唯一有风险步,做足保护)**:`ec_write_test.sh` 先在空闲低温下试写,
   发现 `0x0A08/0A0A/0A0B` 写入会被 EC 覆盖(纯回读寄存器)。
   `ec_findctl.sh` 改用"往上写让风扇加速"(空闲加速绝对安全)定位控制寄存器 ——
   命中 **`0x0A18`**:写 10 使 RPM 从 2513 爬到 3636,而 CPU 温度不变。
6. **突破 zero-RPM**:`ec_slowdown.sh` 发现单写 0x0A18 只能降到 ~2000 RPM 地板
   (EC 自动曲线的保底)。`ec_scan_flags.sh` 全段扫描找"稳定非零"的模式标志候选
   (顺带发现 `0x0A70-0x0A8F` 是电池厂商/序列号 ASCII 字符串 → **硬禁区**)。
   `ec_mode.sh` 逐个试翻转候选,命中 **`0x0A19`**:`0x0A19=0` + `0x0A18=0` → **0 RPM**。
7. **持续性验证**:`ec_zerohold.sh` 用每秒重写的方式对抗 EC 伺服回收,实测
   **40 秒里 37 秒精确 0 RPM,CPU 仅 43→45°C**。确认可稳定停转且温度安全。

## 最终结论(寄存器)

| 寄存器 | 作用 |
|---|---|
| `0x0A19` | 风扇使能/模式:`0`→停转,`1`→~1846,`85`→2331,`170`→2639 |
| `0x0A18` | 风扇转速档/duty:写高→加速(10→3636),写低→降速 |
| `0x0A00/0x0A01` | Fan0 RPM 回读(hi/lo) |
| `0x0A04` | RPM/100 回读 |
| `0x0A08/0A0A/0A0B` | 当前状态回读(写入会被覆盖,非控制入口) |

- **停转**:`WTER(0x0A19,0)` + `WTER(0x0A18,0)`。
- **恢复自动**:`WTER(0x0A19,1)` + `WTER(0x0A18,3)`,或直接重启。
- EC 后台自动曲线会缓慢把值顶回,需每 1-2 秒重写压住。
- **硬禁区**:`0x0A70-0x0A8F`(电池厂商/序列号),绝不可写。

## 安全性

- 读零风险;写风扇寄存器在空闲低温下零风险。
- EC RAM 易失:任何异常**断电/重启 100% 恢复**;全程不写 flash、不动 BIOS。
- 部署必须带温度阈值,超阈值自动交还 EC 自动散热。

## 归档文件说明

本次研究的临时脚本/日志/输出已原封不动打包在同目录(或 /data/Sea/archives)的
tar.gz 中,包括:`ec_*.sh/.txt`(EC 实验)、`nbfc_*`、`*_acpi_call*`、
`ec_decompile*`/`decompile_only*`、`DSDT.dsl`、`wter_fan_extract.txt` 等。
(注:另有一个 2.2GB 的 Windows 软件解包目录 `pcm_re/` 未纳入压缩包,体积过大、今后用不到。)
