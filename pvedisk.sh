#!/usr/bin/env bash
# -----------------------------------------------------------------------------
#  PVE 一键扩容脚本  (v7.1)   ——  块存储 (LVM‑Thin) & “pvedisk” 快速启动
# -----------------------------------------------------------------------------
#  新增特性
#  ✦  `pvedisk install`  —— 把脚本复制到 /usr/local/bin/pvedisk 并赋可执行权；
#                           之后任何位置直接敲 `pvedisk` 即可运行主逻辑。
#  ✦  `pvedisk --help`    —— 简易帮助信息。
#  ✦  若系统无 sudo (如默认 root 环境)，自动用普通 install 命令，不再报错。
# -----------------------------------------------------------------------------
#  安装一次：
#     wget -O pvedisk https://raw.githubusercontent.com/<user>/pve_add_lvm/main/pvedisk.sh
#     bash pvedisk install         # root 环境直接 bash，非 root 需 sudo bash
#  以后使用：
#     pvedisk                      # root 环境直接 pvedisk，非 root 需 sudo pvedisk
# -----------------------------------------------------------------------------
set -euo pipefail
shopt -s nocasematch
trap 'echo "\e[1;31m[ERR ]\e[0m 脚本中断 (line $LINENO)"' ERR

HELP_MSG="\nUsage:\n  pvedisk install     # 安装脚本到 /usr/local/bin/pvedisk\n  pvedisk             # 运行交互式磁盘初始化 (需要 root)\n  pvedisk --help      # 显示帮助\n"

###########################################################
# 0. 子命令处理：install / help
###########################################################
if [[ "${1:-}" =~ ^(-h|--help|help)$ ]]; then
  echo -e "$HELP_MSG"; exit 0
fi

if [[ "${1:-}" == "install" ]]; then
  DEST="/usr/local/bin/pvedisk"
  if command -v sudo >/dev/null 2>&1; then
    sudo install -m 755 "$(readlink -f "$0")" "$DEST"
  else
    install -m 755 "$(readlink -f "$0")" "$DEST"
  fi
  echo -e "\e[1;32m[INFO]\e[0m 已安装为 $DEST\n以后可直接运行: pvedisk (或 sudo pvedisk)"
  exit 0
fi

###########################################################
# 1. 权限 & 依赖检查
###########################################################
[[ $EUID -ne 0 ]] && { echo -e "\e[1;31m[ERR ]\e[0m 需要 root，请使用 sudo 或先 su -"; exit 1; }
for cmd in parted pvcreate vgcreate lvcreate pvesm wipefs dmsetup lsblk partprobe findmnt; do
  command -v "$cmd" >/dev/null || { echo "缺少依赖 $cmd (apt install $cmd)"; exit 1; }
done

log()   { echo -e "\e[1;32m[INFO]\e[0m $*"; }
warn()  { echo -e "\e[1;33m[WARN]\e[0m $*"; }
error() { echo -e "\e[1;31m[ERR ]\e[0m $*"; exit 1; }

###########################################################
# 2. 枚举物理磁盘
###########################################################
mapfile -t DISKS < <(lsblk -dn -o NAME,TYPE,RO | awk '$2=="disk" && $3==0 {print $1}')
[[ ${#DISKS[@]} -eq 0 ]] && error "未检测到物理磁盘"

echo -e "\n📜 可选择的磁盘："
for i in "${!DISKS[@]}"; do
  DEV="/dev/${DISKS[$i]}"; SIZE=$(lsblk -dn -o SIZE "$DEV"); MODEL=$(lsblk -dn -o MODEL "$DEV")
  echo "  [$((i+1))]  $DEV  $SIZE  $MODEL"
done
read -rp $'\n🖋 请输入要初始化为 LVM-Thin 的磁盘编号: ' IDX
[[ ! $IDX =~ ^[0-9]+$ || $IDX -lt 1 || $IDX -gt ${#DISKS[@]} ]] && error "编号无效"

DEV="/dev/${DISKS[$((IDX-1))]}"
LETTER="${DEV##*/sd}"
VG="vg_$LETTER"; TP="thin_$LETTER"; STID="lvmthin_$LETTER"; PART="${DEV}1"
log "目标磁盘: $DEV  ➜  VG=$VG / ThinPool=$TP / 存储ID=$STID"

###########################################################
# 3. 检测签名 / 处理保留
###########################################################
HAS_SIG="no"
wipefs -n "$DEV" | grep -qE '.' && HAS_SIG="yes"
lsblk -no NAME "$DEV" | tail -n +2 | grep -q . && HAS_SIG="yes"

if [[ $HAS_SIG == "yes" ]]; then
  warn "$DEV 检测到现有数据/分区:"
  lsblk "$DEV"
  read -rp "保留数据? yes 保留 / no 清空 (yes/no): " KEEP
  case "$KEEP" in
    y|yes) log "选择保留，脚本退出。"; exit 0;;
    n|no)  warn "开始清空 $DEV…";;
    *)     error "请输入 yes 或 no";;
  esac
  for mp in $(findmnt -rn -S "$DEV*" -o TARGET); do warn "卸载 $mp"; umount -lf "$mp" || true; done
  if pvs | grep -q "^ *$DEV"; then
    for vg in $(pvs --noheadings -o vg_name "$DEV" | xargs); do warn "停用 VG $vg"; vgchange -an "$vg" || true; done
  fi
  dmsetup ls --target linear | awk '{print $1" "$2}' | grep "$DEV" | awk '{print $1}' | xargs -r dmsetup remove -f || true
  wipefs -a "$DEV"; sgdisk --zap-all "$DEV" >/dev/null 2>&1 || true
  log "$DEV 已清空签名"
fi

###########################################################
# 4. GPT & 分区
###########################################################
log "写入 GPT 分区表"
parted -s "$DEV" mklabel gpt
parted -s "$DEV" mkpart primary 0% 100%
partprobe "$DEV" || true; udevadm settle
for i in {1..10}; do [[ -b $PART ]] && break; sleep 1; done
[[ ! -b $PART ]] && error "分区节点 $PART 未出现，重启后重试"
log "分区 $PART 就绪"

###########################################################
# 5. 创建 LVM-Thin
###########################################################
log "创建 PV/VG/ThinPool…"
pvcreate -ff -y "$PART"  >/dev/null
vgcreate "$VG" "$PART"   >/dev/null
lvcreate -l 100%FREE --type thin-pool -n "$TP" "$VG" >/dev/null
log "ThinPool 创建完成"

###########################################################
# 6. 注册 PVE 存储
###########################################################
if pvesm status | awk '{print $1}' | grep -qx "$STID"; then
  warn "存储 ID $STID 已存在，跳过添加"
else
  pvesm add lvmthin "$STID" --vgname "$VG" --thinpool "$TP" --content images,rootdir
  log "已注册 PVE 存储 $STID (lvmthin)"
fi

echo -e "\n✅ **成功！** 创建/克隆 VM 时可选存储 '$STID'，支持快照。\n"
