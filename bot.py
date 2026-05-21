#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Telegram 自动下载机器人 · Pyrogram 版  v2.0
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
✅ MTProto 协议 — 无文件大小限制
✅ 实时进度条（速度 / 剩余时间）
✅ 8 种媒体类型自动分类保存
✅ 内联按钮管理菜单（无需输入命令）
✅ 按日期子目录归档
✅ 用户白名单
✅ 并发下载
✅ 从 .env 读取配置
✅ 文件浏览器（分页浏览每种类型）  ← NEW
✅ 单文件删除（含二次确认）        ← NEW
✅ 批量删除（按类型 / 按日期）      ← NEW
✅ 文件详情（大小 / 路径 / 时间）   ← NEW
"""

import asyncio
import logging
import os
import shutil
import time
from datetime import datetime
from pathlib import Path

from dotenv import load_dotenv
from pyrogram import Client, filters
from pyrogram.types import (
    Message,
    CallbackQuery,
    InlineKeyboardMarkup,
    InlineKeyboardButton,
)

# ══════════════════════════════════════════════
#  加载 .env
# ══════════════════════════════════════════════
load_dotenv()

def _require(key: str) -> str:
    v = os.getenv(key, "").strip()
    if not v or v.startswith("your_"):
        raise RuntimeError(f"❌ 请在 .env 中填写 {key}")
    return v

def _int_require(key: str) -> int:
    v = _require(key)
    try:
        return int(v)
    except ValueError:
        raise RuntimeError(f"❌ {key} 必须是整数，当前值：{v!r}")

API_ID    = _int_require("API_ID")
API_HASH  = _require("API_HASH")
BOT_TOKEN = _require("BOT_TOKEN")

DOWNLOAD_ROOT       = Path(os.getenv("DOWNLOAD_ROOT", "./downloads"))
ORGANIZE_BY_DATE    = os.getenv("ORGANIZE_BY_DATE", "true").lower() == "true"
PROGRESS_UPDATE_SEC = float(os.getenv("PROGRESS_UPDATE_SEC", "2.0"))
PAGE_SIZE           = int(os.getenv("PAGE_SIZE", "8"))          # 文件浏览每页条数
ALLOWED_USERS: list[int] = [
    int(x) for x in os.getenv("ALLOWED_USERS", "").split(",") if x.strip().isdigit()
]

# ══════════════════════════════════════════════
#  媒体目录映射
# ══════════════════════════════════════════════
MEDIA_DIRS: dict[str, Path] = {
    "photo"     : DOWNLOAD_ROOT / "photos",
    "video"     : DOWNLOAD_ROOT / "videos",
    "audio"     : DOWNLOAD_ROOT / "audios",
    "voice"     : DOWNLOAD_ROOT / "voices",
    "document"  : DOWNLOAD_ROOT / "documents",
    "sticker"   : DOWNLOAD_ROOT / "stickers",
    "animation" : DOWNLOAD_ROOT / "animations",
    "video_note": DOWNLOAD_ROOT / "video_notes",
}

ENABLED_TYPES: dict[str, bool] = {k: True for k in MEDIA_DIRS}

# ══════════════════════════════════════════════
#  文件注册表（路径 ↔ 短ID，规避 callback 64B 限制）
# ══════════════════════════════════════════════
# { fid(int): Path }
_FILE_REGISTRY: dict[int, Path] = {}
_fid_counter = 0
_PATH_TO_FID: dict[str, int] = {}   # 反向索引，避免重复注册

def _register_path(p: Path) -> int:
    """注册路径，返回短整型 ID（幂等）"""
    global _fid_counter
    key = str(p.resolve())
    if key in _PATH_TO_FID:
        return _PATH_TO_FID[key]
    _fid_counter += 1
    _FILE_REGISTRY[_fid_counter] = p
    _PATH_TO_FID[key] = _fid_counter
    return _fid_counter

def _lookup_path(fid: int) -> Path | None:
    return _FILE_REGISTRY.get(fid)

def _unregister_path(fid: int):
    p = _FILE_REGISTRY.pop(fid, None)
    if p:
        _PATH_TO_FID.pop(str(p.resolve()), None)

# ══════════════════════════════════════════════
#  日志
# ══════════════════════════════════════════════
logging.basicConfig(
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
    level=logging.INFO,
)
logger = logging.getLogger(__name__)

# ══════════════════════════════════════════════
#  Pyrogram 客户端
# ══════════════════════════════════════════════
bot = Client(
    "tg_downloader_session",
    api_id=API_ID,
    api_hash=API_HASH,
    bot_token=BOT_TOKEN,
)

# ══════════════════════════════════════════════
#  工具函数
# ══════════════════════════════════════════════

def fmt_size(n: int) -> str:
    if n < 1024:     return f"{n} B"
    if n < 1 << 20:  return f"{n / 1024:.1f} KB"
    if n < 1 << 30:  return f"{n / (1 << 20):.1f} MB"
    return f"{n / (1 << 30):.2f} GB"

def fmt_speed(bps: float) -> str:
    if bps < 1024:    return f"{bps:.0f} B/s"
    if bps < 1 << 20: return f"{bps / 1024:.1f} KB/s"
    return f"{bps / (1 << 20):.1f} MB/s"

def fmt_eta(sec: float) -> str:
    sec = max(0, int(sec))
    h, rem = divmod(sec, 3600)
    m, s   = divmod(rem, 60)
    if h: return f"{h}h {m:02d}m"
    if m: return f"{m}m {s:02d}s"
    return f"{s}s"

def fmt_ts(ts: float) -> str:
    return datetime.fromtimestamp(ts).strftime("%Y-%m-%d %H:%M:%S")

def pbar(pct: float, width: int = 16) -> str:
    filled = int(width * pct / 100)
    return "█" * filled + "░" * (width - filled)

def media_emoji(t: str) -> str:
    return {
        "photo": "🖼️", "video": "🎬", "audio": "🎵",
        "voice": "🎤", "document": "📄", "sticker": "😄",
        "animation": "🎞️", "video_note": "📹",
    }.get(t, "📁")

def get_save_dir(media_type: str) -> Path:
    base = MEDIA_DIRS.get(media_type, DOWNLOAD_ROOT / "others")
    if ORGANIZE_BY_DATE:
        base = base / datetime.now().strftime("%Y-%m-%d")
    base.mkdir(parents=True, exist_ok=True)
    return base

def safe_path(save_dir: Path, name: str) -> Path:
    p = save_dir / name
    if p.exists():
        stem, suffix = Path(name).stem, Path(name).suffix
        p = save_dir / f"{stem}_{datetime.now().strftime('%H%M%S%f')}{suffix}"
    return p

def is_allowed(uid: int | None) -> bool:
    if uid is None:
        return True
    return not ALLOWED_USERS or uid in ALLOWED_USERS

def detect_media(msg: Message) -> tuple[str, str] | tuple[None, None]:
    mid = msg.id
    if msg.photo:        return "photo",      f"photo_{mid}.jpg"
    if msg.video:        return "video",       msg.video.file_name      or f"video_{mid}.mp4"
    if msg.audio:        return "audio",       msg.audio.file_name      or f"audio_{mid}.mp3"
    if msg.voice:        return "voice",       f"voice_{mid}.ogg"
    if msg.document:     return "document",    msg.document.file_name   or f"document_{mid}"
    if msg.sticker:
        s   = msg.sticker
        ext = ".webm" if s.is_video else (".tgs" if s.is_animated else ".webp")
        return "sticker", f"sticker_{mid}{ext}"
    if msg.animation:    return "animation",   msg.animation.file_name  or f"animation_{mid}.mp4"
    if msg.video_note:   return "video_note",  f"videonote_{mid}.mp4"
    return None, None

def get_file_size(msg: Message) -> int:
    for attr in ("photo","video","audio","voice","document","sticker","animation","video_note"):
        obj = getattr(msg, attr, None)
        if obj:
            return getattr(obj, "file_size", 0) or 0
    return 0

# ══════════════════════════════════════════════
#  文件列表辅助
# ══════════════════════════════════════════════

def list_files_for_type(mtype: str) -> list[Path]:
    """返回该类型目录下所有文件，按修改时间倒序"""
    base = MEDIA_DIRS.get(mtype)
    if not base or not base.exists():
        return []
    files = sorted(
        (f for f in base.rglob("*") if f.is_file()),
        key=lambda f: f.stat().st_mtime,
        reverse=True,
    )
    return files

def list_dates_for_type(mtype: str) -> list[str]:
    """返回该类型目录下存在的日期子目录名（倒序）"""
    base = MEDIA_DIRS.get(mtype)
    if not base or not base.exists():
        return []
    dates = sorted(
        (d.name for d in base.iterdir() if d.is_dir()),
        reverse=True,
    )
    return dates

# ══════════════════════════════════════════════
#  统计数据
# ══════════════════════════════════════════════

def calc_stats() -> tuple[dict, int, int]:
    per = {}
    tf = ts = 0
    for mtype, base in MEDIA_DIRS.items():
        if not base.exists():
            per[mtype] = (0, 0)
            continue
        files = [f for f in base.rglob("*") if f.is_file()]
        cnt   = len(files)
        size  = sum(f.stat().st_size for f in files)
        per[mtype] = (cnt, size)
        tf += cnt
        ts += size
    return per, tf, ts

# ══════════════════════════════════════════════
#  键盘构建
# ══════════════════════════════════════════════

def kb_main() -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup([
        [
            InlineKeyboardButton("📊 下载统计",  callback_data="menu:status"),
            InlineKeyboardButton("📁 目录结构",  callback_data="menu:dirs"),
        ],
        [
            InlineKeyboardButton("🔍 浏览文件",  callback_data="menu:browse"),
            InlineKeyboardButton("🗑️ 删除文件",  callback_data="menu:delete"),
        ],
        [
            InlineKeyboardButton("🔧 类型开关",  callback_data="menu:types"),
            InlineKeyboardButton("⚙️ 当前设置",  callback_data="menu:settings"),
        ],
        [
            InlineKeyboardButton("🔄 刷新菜单",  callback_data="menu:home"),
        ],
    ])

def kb_back(target: str = "menu:home") -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup([
        [InlineKeyboardButton("« 返回", callback_data=target)]
    ])

def kb_types() -> InlineKeyboardMarkup:
    rows = []
    items = list(MEDIA_DIRS.keys())
    for i in range(0, len(items), 2):
        row = []
        for mtype in items[i:i+2]:
            flag  = "✅" if ENABLED_TYPES[mtype] else "❌"
            label = f"{flag} {media_emoji(mtype)} {mtype}"
            row.append(InlineKeyboardButton(label, callback_data=f"toggle:{mtype}"))
        rows.append(row)
    rows.append([InlineKeyboardButton("« 返回主菜单", callback_data="menu:home")])
    return InlineKeyboardMarkup(rows)

def kb_type_select(prefix: str, back: str = "menu:home") -> InlineKeyboardMarkup:
    """通用：选择媒体类型的键盘（用于浏览/删除入口）"""
    rows = []
    items = list(MEDIA_DIRS.keys())
    for i in range(0, len(items), 2):
        row = []
        for mtype in items[i:i+2]:
            per, _, _ = calc_stats()
            cnt = per.get(mtype, (0, 0))[0]
            label = f"{media_emoji(mtype)} {mtype} ({cnt})"
            row.append(InlineKeyboardButton(label, callback_data=f"{prefix}:{mtype}:0"))
        rows.append(row)
    rows.append([InlineKeyboardButton("« 返回主菜单", callback_data=back)])
    return InlineKeyboardMarkup(rows)

def kb_file_list(mtype: str, page: int, files: list[Path]) -> InlineKeyboardMarkup:
    """分页文件列表键盘"""
    total   = len(files)
    total_p = max(1, (total + PAGE_SIZE - 1) // PAGE_SIZE)
    start   = page * PAGE_SIZE
    end     = min(start + PAGE_SIZE, total)
    page_files = files[start:end]

    rows = []
    for f in page_files:
        fid   = _register_path(f)
        label = f"📄 {f.name[:38]}"
        rows.append([InlineKeyboardButton(label, callback_data=f"finfo:{fid}")])

    # 翻页
    nav = []
    if page > 0:
        nav.append(InlineKeyboardButton("◀ 上一页", callback_data=f"browse:{mtype}:{page-1}"))
    nav.append(InlineKeyboardButton(f"{page+1}/{total_p}", callback_data="noop"))
    if page < total_p - 1:
        nav.append(InlineKeyboardButton("下一页 ▶", callback_data=f"browse:{mtype}:{page+1}"))
    if nav:
        rows.append(nav)

    rows.append([
        InlineKeyboardButton("« 返回类型列表", callback_data="menu:browse"),
        InlineKeyboardButton("🏠 主菜单",      callback_data="menu:home"),
    ])
    return InlineKeyboardMarkup(rows)

def kb_file_info(fid: int, mtype: str, page: int) -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup([
        [
            InlineKeyboardButton("🗑️ 删除此文件",  callback_data=f"fdel_ask:{fid}:{mtype}:{page}"),
        ],
        [
            InlineKeyboardButton("« 返回列表",    callback_data=f"browse:{mtype}:{page}"),
            InlineKeyboardButton("🏠 主菜单",     callback_data="menu:home"),
        ],
    ])

def kb_file_del_confirm(fid: int, mtype: str, page: int) -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup([
        [
            InlineKeyboardButton("⚠️ 确认删除",   callback_data=f"fdel_do:{fid}:{mtype}:{page}"),
            InlineKeyboardButton("✗ 取消",        callback_data=f"finfo:{fid}"),
        ],
    ])

def kb_batch_type_select(back: str = "menu:delete") -> InlineKeyboardMarkup:
    """删除入口：选择类型 + 全部删除"""
    rows = []
    items = list(MEDIA_DIRS.keys())
    for i in range(0, len(items), 2):
        row = []
        for mtype in items[i:i+2]:
            per, _, _ = calc_stats()
            cnt = per.get(mtype, (0, 0))[0]
            label = f"{media_emoji(mtype)} {mtype} ({cnt})"
            row.append(InlineKeyboardButton(label, callback_data=f"bdel_ask:{mtype}"))
        rows.append(row)
    rows.append([
        InlineKeyboardButton("💣 删除全部",   callback_data="bdel_ask:ALL"),
        InlineKeyboardButton("« 返回主菜单", callback_data="menu:home"),
    ])
    return InlineKeyboardMarkup(rows)

def kb_batch_del_confirm(mtype: str) -> InlineKeyboardMarkup:
    label = "全部" if mtype == "ALL" else mtype
    return InlineKeyboardMarkup([
        [
            InlineKeyboardButton(f"⚠️ 确认删除 {label}", callback_data=f"bdel_do:{mtype}"),
            InlineKeyboardButton("✗ 取消",               callback_data="menu:delete"),
        ],
    ])

# ══════════════════════════════════════════════
#  菜单文本构建
# ══════════════════════════════════════════════

def text_home(name: str) -> str:
    enabled   = sum(1 for v in ENABLED_TYPES.values() if v)
    _, tf, ts = calc_stats()
    return (
        f"👋 你好，**{name}**！\n\n"
        f"📥 **Telegram 自动下载机器人**\n"
        f"━━━━━━━━━━━━━━━━━━━━\n"
        f"🗂️ 已保存文件：**{tf}** 个  ({fmt_size(ts)})\n"
        f"🔛 启用类型：**{enabled}** / {len(MEDIA_DIRS)}\n"
        f"📂 根目录：`{DOWNLOAD_ROOT.resolve()}`\n\n"
        f"直接发送或转发媒体给我，自动保存 👇"
    )

def text_status() -> str:
    per, tf, ts = calc_stats()
    lines = ["📊 **下载统计**\n"]
    for mtype, (cnt, size) in per.items():
        flag = "✅" if ENABLED_TYPES[mtype] else "⏸"
        bar  = "▓" * min(cnt // max(1, tf // 10 + 1), 8) if tf else ""
        lines.append(f"  {flag} {media_emoji(mtype)} **{mtype}**：{cnt} 个  {fmt_size(size)}  {bar}")
    lines.append(f"\n📦 **合计**：{tf} 个文件，{fmt_size(ts)}")
    lines.append(f"\n🕐 更新时间：{datetime.now().strftime('%H:%M:%S')}")
    return "\n".join(lines)

def text_dirs() -> str:
    lines = [f"📁 **目录结构**\n`{DOWNLOAD_ROOT.resolve()}`\n"]
    for mtype, path in MEDIA_DIRS.items():
        exists = path.exists()
        mark   = "✅" if exists else "⬜"
        cnt    = len([f for f in path.rglob("*") if f.is_file()]) if exists else 0
        flag   = "▶" if ENABLED_TYPES[mtype] else "⏸"
        lines.append(
            f"  {mark}{flag} {media_emoji(mtype)} "
            f"`{path.relative_to(DOWNLOAD_ROOT)}`  _{cnt} 个_"
        )
    return "\n".join(lines)

def text_types() -> str:
    lines = ["🔧 **媒体类型开关**\n点击按钮切换启用 / 停用\n"]
    for mtype, enabled in ENABLED_TYPES.items():
        state = "✅ 启用" if enabled else "❌ 停用"
        lines.append(f"  {media_emoji(mtype)} {mtype}：{state}")
    return "\n".join(lines)

def text_settings() -> str:
    wl = "全部用户" if not ALLOWED_USERS else "、".join(str(u) for u in ALLOWED_USERS)
    enabled_list = [k for k, v in ENABLED_TYPES.items() if v]
    return (
        "⚙️ **当前运行设置**\n\n"
        f"📂 下载根目录\n`{DOWNLOAD_ROOT.resolve()}`\n\n"
        f"📅 按日期归档：{'✅ 开启' if ORGANIZE_BY_DATE else '❌ 关闭'}\n"
        f"⏱ 进度刷新间隔：{PROGRESS_UPDATE_SEC}s\n"
        f"📋 文件浏览每页：{PAGE_SIZE} 条\n"
        f"👤 白名单：{wl}\n\n"
        f"🔛 启用的类型：\n"
        + "  " + "  ".join(media_emoji(t) for t in enabled_list)
    )

def text_browse_select() -> str:
    per, tf, ts = calc_stats()
    lines = [f"🔍 **浏览文件**  共 {tf} 个 / {fmt_size(ts)}\n\n选择要浏览的媒体类型："]
    for mtype, (cnt, size) in per.items():
        lines.append(f"  {media_emoji(mtype)} **{mtype}**：{cnt} 个  {fmt_size(size)}")
    return "\n".join(lines)

def text_file_list(mtype: str, page: int, files: list[Path]) -> str:
    total   = len(files)
    total_p = max(1, (total + PAGE_SIZE - 1) // PAGE_SIZE)
    start   = page * PAGE_SIZE
    end     = min(start + PAGE_SIZE, total)
    lines   = [
        f"{media_emoji(mtype)} **{mtype}** 文件列表",
        f"共 {total} 个文件  第 {page+1}/{total_p} 页\n",
    ]
    for i, f in enumerate(files[start:end], start=start+1):
        stat  = f.stat()
        mtime = fmt_ts(stat.st_mtime)[:10]
        lines.append(f"  `{i}.` {f.name[:36]}  _{fmt_size(stat.st_size)}_  {mtime}")
    lines.append("\n点击文件名查看详情 / 删除")
    return "\n".join(lines)

def text_file_info(fid: int) -> str:
    p = _lookup_path(fid)
    if not p or not p.exists():
        return "❌ 文件不存在或已被删除"
    stat = p.stat()
    rel  = p.relative_to(DOWNLOAD_ROOT) if DOWNLOAD_ROOT in p.parents else p
    return (
        f"📄 **文件详情**\n\n"
        f"🏷 名称：`{p.name}`\n"
        f"📦 大小：{fmt_size(stat.st_size)}\n"
        f"🕐 创建：{fmt_ts(stat.st_ctime)}\n"
        f"🕑 修改：{fmt_ts(stat.st_mtime)}\n"
        f"📂 路径：`{rel}`\n"
        f"💾 完整路径：\n`{p.resolve()}`"
    )

def text_delete_select() -> str:
    per, tf, ts = calc_stats()
    lines = [f"🗑️ **删除文件**  共 {tf} 个 / {fmt_size(ts)}\n\n选择要删除的范围："]
    for mtype, (cnt, size) in per.items():
        lines.append(f"  {media_emoji(mtype)} **{mtype}**：{cnt} 个  {fmt_size(size)}")
    lines.append(f"\n⚠️ 删除操作**不可恢复**，请谨慎操作！")
    return "\n".join(lines)

# ══════════════════════════════════════════════
#  进度回调工厂
# ══════════════════════════════════════════════

def make_progress(status_msg: Message, file_name: str,
                  media_type: str, total_hint: int = 0):
    last_t  = [0.0]
    start_t = [time.monotonic()]

    async def _cb(current: int, total: int):
        now = time.monotonic()
        if (now - last_t[0]) < PROGRESS_UPDATE_SEC and current < total:
            return
        last_t[0] = now
        total_real = total or total_hint or current
        pct        = current / total_real * 100 if total_real else 0
        elapsed    = max(now - start_t[0], 0.001)
        speed      = current / elapsed
        eta        = (total_real - current) / speed if speed > 0 and total_real > current else 0
        text = (
            f"{media_emoji(media_type)} **正在下载**\n"
            f"`{file_name}`\n\n"
            f"`{pbar(pct)}` **{pct:.1f}%**\n"
            f"📦 {fmt_size(current)} / {fmt_size(total_real)}\n"
            f"⚡ {fmt_speed(speed)}   ⏱ 剩余 {fmt_eta(eta)}"
        )
        try:
            await status_msg.edit_text(text)
        except Exception:
            pass

    return _cb

# ══════════════════════════════════════════════
#  命令处理器
# ══════════════════════════════════════════════

@bot.on_message(filters.command("start") & (filters.private | filters.group))
async def cmd_start(_, msg: Message):
    uid = msg.from_user.id if msg.from_user else None
    if not is_allowed(uid):
        return
    name = msg.from_user.first_name if msg.from_user else "用户"
    await msg.reply_text(text_home(name), reply_markup=kb_main())

@bot.on_message(filters.command("menu") & (filters.private | filters.group))
async def cmd_menu(_, msg: Message):
    uid = msg.from_user.id if msg.from_user else None
    if not is_allowed(uid):
        return
    name = msg.from_user.first_name if msg.from_user else "用户"
    await msg.reply_text(text_home(name), reply_markup=kb_main())

@bot.on_message(filters.command("status") & (filters.private | filters.group))
async def cmd_status(_, msg: Message):
    uid = msg.from_user.id if msg.from_user else None
    if not is_allowed(uid):
        return
    await msg.reply_text(text_status(), reply_markup=kb_back())

@bot.on_message(filters.command("dirs") & (filters.private | filters.group))
async def cmd_dirs(_, msg: Message):
    uid = msg.from_user.id if msg.from_user else None
    if not is_allowed(uid):
        return
    await msg.reply_text(text_dirs(), reply_markup=kb_back())

@bot.on_message(filters.command("browse") & (filters.private | filters.group))
async def cmd_browse(_, msg: Message):
    uid = msg.from_user.id if msg.from_user else None
    if not is_allowed(uid):
        return
    await msg.reply_text(
        text_browse_select(),
        reply_markup=kb_type_select("browse", back="menu:home"),
    )

@bot.on_message(filters.command("delete") & (filters.private | filters.group))
async def cmd_delete(_, msg: Message):
    uid = msg.from_user.id if msg.from_user else None
    if not is_allowed(uid):
        return
    await msg.reply_text(text_delete_select(), reply_markup=kb_batch_type_select())

# ══════════════════════════════════════════════
#  内联按钮回调处理
# ══════════════════════════════════════════════

@bot.on_callback_query()
async def on_callback(_, cq: CallbackQuery):
    uid = cq.from_user.id
    if not is_allowed(uid):
        await cq.answer("⛔ 无权限", show_alert=True)
        return

    data = cq.data
    name = cq.from_user.first_name or "用户"

    # ── 无操作占位 ────────────────────────────
    if data == "noop":
        await cq.answer()
        return

    # ── 主菜单 ────────────────────────────────
    if data == "menu:home":
        await cq.message.edit_text(text_home(name), reply_markup=kb_main())
        await cq.answer()

    # ── 下载统计 ──────────────────────────────
    elif data == "menu:status":
        await cq.message.edit_text(text_status(), reply_markup=InlineKeyboardMarkup([
            [
                InlineKeyboardButton("🔄 刷新",  callback_data="menu:status"),
                InlineKeyboardButton("« 返回",   callback_data="menu:home"),
            ]
        ]))
        await cq.answer("已刷新")

    # ── 目录结构 ──────────────────────────────
    elif data == "menu:dirs":
        await cq.message.edit_text(text_dirs(), reply_markup=InlineKeyboardMarkup([
            [
                InlineKeyboardButton("🔄 刷新",  callback_data="menu:dirs"),
                InlineKeyboardButton("« 返回",   callback_data="menu:home"),
            ]
        ]))
        await cq.answer()

    # ── 类型开关面板 ──────────────────────────
    elif data == "menu:types":
        await cq.message.edit_text(text_types(), reply_markup=kb_types())
        await cq.answer()

    # ── 切换单个类型 ──────────────────────────
    elif data.startswith("toggle:"):
        mtype = data.split(":", 1)[1]
        if mtype in ENABLED_TYPES:
            ENABLED_TYPES[mtype] = not ENABLED_TYPES[mtype]
            state = "✅ 已启用" if ENABLED_TYPES[mtype] else "❌ 已停用"
            await cq.answer(f"{media_emoji(mtype)} {mtype} {state}")
        await cq.message.edit_text(text_types(), reply_markup=kb_types())

    # ── 当前设置 ──────────────────────────────
    elif data == "menu:settings":
        await cq.message.edit_text(text_settings(), reply_markup=kb_back())
        await cq.answer()

    # ════════════════════════════════════════════
    #  ★ 浏览文件
    # ════════════════════════════════════════════

    elif data == "menu:browse":
        await cq.message.edit_text(
            text_browse_select(),
            reply_markup=kb_type_select("browse", back="menu:home"),
        )
        await cq.answer()

    elif data.startswith("browse:"):
        # browse:{mtype}:{page}
        parts = data.split(":")
        mtype, page = parts[1], int(parts[2])
        files = list_files_for_type(mtype)
        if not files:
            await cq.answer(f"📭 {mtype} 目录为空", show_alert=True)
            return
        await cq.message.edit_text(
            text_file_list(mtype, page, files),
            reply_markup=kb_file_list(mtype, page, files),
        )
        await cq.answer()

    # ── 文件详情 ──────────────────────────────
    elif data.startswith("finfo:"):
        fid = int(data.split(":")[1])
        p   = _lookup_path(fid)
        if not p or not p.exists():
            await cq.answer("❌ 文件不存在", show_alert=True)
            return
        # 猜回媒体类型和页码（用于返回）
        mtype = next(
            (mt for mt, base in MEDIA_DIRS.items() if base in p.parents or base == p.parent.parent),
            "document"
        )
        files = list_files_for_type(mtype)
        page  = next((i // PAGE_SIZE for i, f in enumerate(files) if f == p), 0)
        await cq.message.edit_text(
            text_file_info(fid),
            reply_markup=kb_file_info(fid, mtype, page),
        )
        await cq.answer()

    # ── 单文件删除：确认询问 ──────────────────
    elif data.startswith("fdel_ask:"):
        # fdel_ask:{fid}:{mtype}:{page}
        parts = data.split(":")
        fid, mtype, page = int(parts[1]), parts[2], int(parts[3])
        p = _lookup_path(fid)
        if not p or not p.exists():
            await cq.answer("❌ 文件不存在", show_alert=True)
            return
        await cq.message.edit_text(
            f"🗑️ **确认删除？**\n\n"
            f"📄 `{p.name}`\n"
            f"📦 {fmt_size(p.stat().st_size)}\n"
            f"📂 `{p.parent}`\n\n"
            f"⚠️ 此操作**不可恢复**！",
            reply_markup=kb_file_del_confirm(fid, mtype, page),
        )
        await cq.answer()

    # ── 单文件删除：执行 ──────────────────────
    elif data.startswith("fdel_do:"):
        # fdel_do:{fid}:{mtype}:{page}
        parts = data.split(":")
        fid, mtype, page = int(parts[1]), parts[2], int(parts[3])
        p = _lookup_path(fid)
        if not p or not p.exists():
            await cq.answer("❌ 文件已不存在", show_alert=True)
            # 返回列表
            files = list_files_for_type(mtype)
            await cq.message.edit_text(
                text_file_list(mtype, page, files),
                reply_markup=kb_file_list(mtype, page, files),
            )
            return

        name_del = p.name
        size_del = p.stat().st_size
        try:
            p.unlink()
            _unregister_path(fid)
            # 清理空目录
            try:
                p.parent.rmdir()
            except OSError:
                pass
            logger.info(f"🗑️ 已删除 [{mtype}] {name_del} ({fmt_size(size_del)})")
        except Exception as exc:
            await cq.answer(f"❌ 删除失败：{exc}", show_alert=True)
            return

        await cq.answer(f"✅ 已删除 {name_del}")
        # 刷新列表
        files = list_files_for_type(mtype)
        # 防止页码越界
        total_p = max(1, (len(files) + PAGE_SIZE - 1) // PAGE_SIZE)
        page    = min(page, total_p - 1)
        if files:
            await cq.message.edit_text(
                text_file_list(mtype, page, files),
                reply_markup=kb_file_list(mtype, page, files),
            )
        else:
            await cq.message.edit_text(
                f"✅ **已删除** `{name_del}`\n\n📭 {mtype} 目录现在为空。",
                reply_markup=kb_back("menu:browse"),
            )

    # ════════════════════════════════════════════
    #  ★ 批量删除
    # ════════════════════════════════════════════

    elif data == "menu:delete":
        await cq.message.edit_text(text_delete_select(), reply_markup=kb_batch_type_select())
        await cq.answer()

    # ── 批量删除：确认询问 ────────────────────
    elif data.startswith("bdel_ask:"):
        mtype = data.split(":", 1)[1]
        if mtype == "ALL":
            _, tf, ts = calc_stats()
            desc = f"**全部** {tf} 个文件  {fmt_size(ts)}"
        else:
            per, _, _ = calc_stats()
            cnt, size = per.get(mtype, (0, 0))
            em   = media_emoji(mtype)
            desc = f"{em} **{mtype}**  {cnt} 个文件  {fmt_size(size)}"

        await cq.message.edit_text(
            f"🗑️ **批量删除确认**\n\n"
            f"即将删除：{desc}\n\n"
            f"⚠️ 此操作**永久删除磁盘文件，不可恢复**！",
            reply_markup=kb_batch_del_confirm(mtype),
        )
        await cq.answer()

    # ── 批量删除：执行 ────────────────────────
    elif data.startswith("bdel_do:"):
        mtype = data.split(":", 1)[1]
        deleted_cnt  = 0
        deleted_size = 0
        errors       = []

        targets: list[Path] = []
        if mtype == "ALL":
            for base in MEDIA_DIRS.values():
                if base.exists():
                    targets.append(base)
        else:
            base = MEDIA_DIRS.get(mtype)
            if base and base.exists():
                targets.append(base)

        for base in targets:
            try:
                files = [f for f in base.rglob("*") if f.is_file()]
                for f in files:
                    sz = f.stat().st_size
                    fid_key = _PATH_TO_FID.get(str(f.resolve()))
                    f.unlink()
                    deleted_cnt  += 1
                    deleted_size += sz
                    if fid_key:
                        _FILE_REGISTRY.pop(fid_key, None)
                        _PATH_TO_FID.pop(str(f.resolve()), None)
                # 删除空子目录
                for d in sorted(base.rglob("*"), reverse=True):
                    if d.is_dir():
                        try:
                            d.rmdir()
                        except OSError:
                            pass
            except Exception as exc:
                errors.append(str(exc))

        label = "全部" if mtype == "ALL" else mtype
        logger.info(f"🗑️ 批量删除 [{label}] {deleted_cnt} 个文件  {fmt_size(deleted_size)}")

        err_text = f"\n⚠️ {len(errors)} 个错误" if errors else ""
        await cq.message.edit_text(
            f"✅ **批量删除完成**\n\n"
            f"🗂️ 范围：**{label}**\n"
            f"📄 已删除：**{deleted_cnt}** 个文件\n"
            f"💾 释放空间：**{fmt_size(deleted_size)}**{err_text}",
            reply_markup=InlineKeyboardMarkup([
                [
                    InlineKeyboardButton("🗑️ 继续删除", callback_data="menu:delete"),
                    InlineKeyboardButton("🏠 主菜单",   callback_data="menu:home"),
                ]
            ]),
        )
        await cq.answer(f"✅ 已删除 {deleted_cnt} 个文件", show_alert=True)

    else:
        await cq.answer("未知操作")

# ══════════════════════════════════════════════
#  核心：媒体消息处理
# ══════════════════════════════════════════════

MEDIA_FILTER = (
    filters.photo      |
    filters.video      |
    filters.audio      |
    filters.voice      |
    filters.document   |
    filters.sticker    |
    filters.animation  |
    filters.video_note
)

@bot.on_message(MEDIA_FILTER & (filters.private | filters.group))
async def handle_media(_client: Client, msg: Message):
    uid = msg.from_user.id if msg.from_user else None
    if not is_allowed(uid):
        return

    media_type, file_name = detect_media(msg)
    if media_type is None:
        return

    if not ENABLED_TYPES.get(media_type, True):
        await msg.reply_text(
            f"{media_emoji(media_type)} **{media_type}** 类型已停用，跳过下载。\n"
            f"可在菜单 → 🔧 类型开关 中重新启用。",
            reply_markup=InlineKeyboardMarkup([[
                InlineKeyboardButton("🔧 打开类型开关", callback_data="menu:types")
            ]])
        )
        return

    safe_name = "".join(c if c not in r'\/:*?"<>|' else "_" for c in file_name)
    save_dir  = get_save_dir(media_type)
    save_path = safe_path(save_dir, safe_name)
    file_size = get_file_size(msg)
    em        = media_emoji(media_type)

    size_hint = f"  ({fmt_size(file_size)})" if file_size else ""
    status = await msg.reply_text(f"{em} 准备下载{size_hint}\n`{safe_name}` ...")

    progress_cb = make_progress(status, safe_name, media_type, file_size)

    t0 = time.monotonic()
    try:
        await msg.download(file_name=str(save_path), progress=progress_cb)
    except Exception as exc:
        logger.error(f"下载失败 [{media_type}] {safe_name}: {exc}")
        await status.edit_text(f"❌ **下载失败**\n`{exc}`")
        return

    elapsed  = time.monotonic() - t0
    act_size = save_path.stat().st_size if save_path.exists() else 0
    avg_spd  = act_size / elapsed if elapsed > 0 else 0

    # 注册到文件表，供浏览/删除使用
    fid = _register_path(save_path)

    logger.info(f"✅ [{media_type}] {save_path.name} ({fmt_size(act_size)}, {fmt_speed(avg_spd)}, {elapsed:.1f}s)")

    await status.edit_text(
        f"{em} **下载完成！**\n\n"
        f"📝 `{save_path.name}`\n"
        f"📦 {fmt_size(act_size)}\n"
        f"⚡ 均速 {fmt_speed(avg_spd)}\n"
        f"⏱ 耗时 {elapsed:.1f}s\n"
        f"💾 `{save_path}`",
        reply_markup=InlineKeyboardMarkup([
            [
                InlineKeyboardButton("🔍 查看详情",   callback_data=f"finfo:{fid}"),
                InlineKeyboardButton("🗑️ 立即删除",   callback_data=f"fdel_ask:{fid}:{media_type}:0"),
            ],
            [
                InlineKeyboardButton("📊 查看统计",   callback_data="menu:status"),
                InlineKeyboardButton("🏠 主菜单",     callback_data="menu:home"),
            ],
        ])
    )

# ══════════════════════════════════════════════
#  入口
# ══════════════════════════════════════════════

if __name__ == "__main__":
    DOWNLOAD_ROOT.mkdir(parents=True, exist_ok=True)
    logger.info(f"📁 下载目录：{DOWNLOAD_ROOT.resolve()}")
    logger.info(f"👤 白名单：{'全部用户' if not ALLOWED_USERS else ALLOWED_USERS}")
    logger.info("🤖 Bot 启动中（Pyrogram · MTProto · 内联菜单 · 浏览/删除）…")
    bot.run()
