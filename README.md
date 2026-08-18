# ImmortalWrt_C2000_MAX

鲲鹏无限 / NRadio C2000-MAX 的 ImmortalWrt 25.12 MediaTek Wi-Fi 7 固件分支。
本分支直接建立在完整 ImmortalWrt/MTK 源码树上，可按普通 ImmortalWrt 工程维护
和编译，不再使用单独的“补丁覆盖层”仓库结构。

当前版本：**V36.01**。

> [!WARNING]
> V36.01 继续使用 `DfsEnable=0` 策略，5 GHz 会跳过 DFS/CAC。160 MHz 覆盖 DFS
> 子信道时可能不符合所在地区法规，不应直接用于公开量产版本。

## 上游与分支关系

- 上游仓库：`https://github.com/chasey-dev/immortalwrt-mt798x-rebase`
- 上游分支：`25.12-dev-wifi7`
- 固定基线：`ed8826fe488c72fbec35d42a965d5862b12a36ed`
- 本项目分支：`c2000max-v36.01`
- 目标：`mediatek/filogic`
- 设备：`nradio,c2000-max`
- 内核：Linux 6.12.94

C2000-MAX 修改仅保存在独立分支中，不需要也不建议向上游提交 PR。以后同步
上游时，应先在测试分支完成 rebase/merge 和实机验证，再更新正式设备分支。

## 功能

- MT7987B、512 MiB DDR3、MT7990AN + MT7976CN Wi-Fi 7；
- 中文 LuCI、默认管理地址 `192.168.66.1`、Argon 与 Bing 壁纸；
- QModem，适配 MT5700M-CN、FM350-GL 和三卡槽 SIM 切换；
- MediaTek HNAT/PPE、LAN/WAN 网口角色切换；
- 加速方式无关的按设备地址限速：HNAT 使用硬件 HQoS，同方向、同速率规则
  自动复用硬件档位并共享档位总带宽；Flow Offloading/普通转发自动使用
  tc/IFB，切换加速方式无需重建规则；
- HNAT 硬件 MIB、Flowtable 与普通 Conntrack 统一流量统计，按 mwan3 实际出口
  区分 5G 和其他/宽带，并提供逐设备明细；
- 官方 APP 本地/远程 SIM、短信、接入设备、重启和蜂窝设置适配；
- OpenClash 0.47.133，默认关闭；
- 风扇、RGB 信号灯、ZRAM、访问控制和硬件状态页面。

V36.01 继承 V35.35 R2 对雷神语言包的修复：无线设置恢复显示“启用”，雷神页面
仍显示“启用雷神加速器”。本版还会每 24 小时安全轮换官方 APP 的 MQTT
云端会话，避免长时间运行后 bridge 仍连接、APP 却显示离线；轮换不会重启
路由器、网络转发或 QModem，并继续禁止上传 root 密码哈希。

## 获取源码

可直接克隆本仓库的 V36.01 分支：

```sh
git clone --branch c2000max-v36.01 \
  https://github.com/jasonBrom/immortalwrt-c2000-max.git
cd immortalwrt-c2000-max
```

如需维护自己的 Fork，保留本分支与上述固定基线的父子关系即可。

## 编译

安装 ImmortalWrt/OpenWrt 常规构建依赖后（主机必须提供 GNU `gawk`，不能用
`mawk` 代替），在源码根目录执行：

```sh
./scripts/feeds update -a
./scripts/feeds install -a

cp configs/c2000max.config .config
make defconfig

export FORCE_UNSAFE_CONFIGURE=1
export SOURCE_DATE_EPOCH=1784306413
export LC_ALL=C
export TZ=UTC
make -j$(nproc) world
```

固定 feed 提交记录在 `feeds.conf.default`。本项目修改过的 LuCI、Adblock Fast
和 NetBird 包位于 `package/custom/`，运行 `feeds install` 时会优先保留本地包，
因此不再需要对下载后的 feeds 手工打补丁。

### SquashFS 兼容性

本分支已在 `target/linux/mediatek/image/Makefile` 中针对 C2000-MAX 禁用 ARM BCJ，
正常 `make` 生成的 rootfs 使用普通 XZ。请勿重新加入 `mksquashfs -Xbcj arm`，
否则设备可能出现 `SQUASHFS error: xz decompression failed`。

## 安装与升级

- 全新安装：将 Release 中的 `*-sdcard.img.gz` 写入整张 SD 卡；
- 正常运行的 V35.24 及以后版本：使用 V36.01 `*-sysupgrade.bin` 并保留配置；
- 不要使用 `sysupgrade -n`；
- 会报 `SQUASHFS error` 的 V35.25 初版不能在线升级，必须重写 V36.01 SD 镜像。

```sh
sysupgrade /tmp/immortalwrt-25.12-snapshot-c2000max-v3601-*-sysupgrade.bin
```

`make` 可直接生成 sysupgrade。完整 SD 镜像需要用户自行提供已验证的 C2000-MAX
参考镜像，再使用 `scripts/c2000max/assemble-c2000max-sdcard.py` 保留 BL2、
U-Boot 环境、Factory 和 FIP。严禁提交 Factory、EEPROM、校准数据、MAC、设备
身份或云端凭据。

## 目录说明

- `configs/c2000max.config`：V36.01 完整构建配置；
- `package/custom/`：板级服务、APP、LuCI、QModem 和固定版本组件；
- `target/linux/mediatek/`：设备树、内核及镜像定义；
- `package/mtk/`、`package/network/`：MediaTek/Wi-Fi/HNAT 适配；
- `defconfig/`：512 MiB 设备精简配置片段；
- `buildinfo/c2000max/`：基线、feeds、软件包和成品元数据；
- `scripts/c2000max/`：C2000-MAX SD 镜像工具。

项目根目录只维护本 README。第三方包子目录中的 README 和开发文档来自各自
上游，予以保留，以维持源码出处和组件使用说明。

## 许可证与安全

本项目自行编写的 C2000-MAX 集成代码以 GPL-2.0-or-later 发布；上游文件、导入
软件包、字体、数据库和二进制继续适用各自许可证，顶层 GPL 不会重新授权它们。
公开再分发前尤其需要检查：

- `package/custom/leigod-acc/files/acc-gw.linux.arm64`：第三方运行时二进制；
- `package/custom/mt5700-web-go`、`package/custom/cnspeedtest`：包元数据声明为
  `Proprietary`；
- `package/custom/c2000max-app/files/usr/lib/c2000max-rweb-compat/`：兼容运行时；
- GeoIP/GeoSite 数据库、字体、图片和 Web UI 资源。

报告问题时请附设备版本、复现步骤和脱敏日志，不要公开 SIM、ICCID、IMEI、MAC、
设备编号、密钥、公网地址或云端凭据。安全问题应通过私密渠道报告。

本项目与 NRadio、鲲鹏无限、MediaTek、雷神、OpenClash 等项目方无隶属或背书
关系。刷写固件可能造成设备无法启动、配置丢失或违反当地无线法规，请保留可恢复
的原厂镜像和串口恢复条件。
