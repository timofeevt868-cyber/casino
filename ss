#!/usr/bin/env python3
"""
🎰 GOLDEN CROWN CASINO BOT — всё в одном файле
Запуск: pip install aiogram==3.13.0  →  python bot.py
"""

import asyncio, logging, random, sqlite3, os
from datetime import date
from aiogram import Bot, Dispatcher, types, F
from aiogram.filters import Command, CommandStart
from aiogram.types import (
    InlineKeyboardMarkup, InlineKeyboardButton,
    LabeledPrice, PreCheckoutQuery,
)
from aiogram.fsm.storage.memory import MemoryStorage
from aiogram.fsm.context import FSMContext
from aiogram.fsm.state import State, StatesGroup
from aiogram.utils.keyboard import InlineKeyboardBuilder

# ══════════════════════════════════════════════════════
#                   ⚙️  НАСТРОЙКИ
# ══════════════════════════════════════════════════════

BOT_TOKEN = "8970836944:AAHhycv65QScpbCB3gqFkuCTiSxaBLfQ1Y0"   # ← токен от @BotFather

# Ваши крипто-кошельки для приёма платежей
CRYPTO_WALLETS = {
    "BTC":  "bc1qxy2kgdygjrsqtzq2n0yrf2493p83kkfjhx0wlh",
    "ETH":  "0x71C7656EC7ab88b098defB751B7401B5f6d8976F",
    "TON":  "UQBvW8Y5FtGcHOos2mMGnSMmMQMokoYM-lAqPQUFYxMbW9aH",
    "USDT": "TN9RBNAKAJKnJBMmh4Ygr5gkuNjnFKsxUE",
}

# Курсы крипты (монет за 1 единицу)
CRYPTO_INFO = {
    "BTC":  {"emoji": "₿",  "rate": 5_000_000, "min": 0.0001},
    "ETH":  {"emoji": "⟠",  "rate": 300_000,   "min": 0.001},
    "TON":  {"emoji": "💎", "rate": 500,        "min": 1.0},
    "USDT": {"emoji": "💵", "rate": 100,        "min": 1.0},
}

WELCOME_BONUS = 50   # монет новичку
DAILY_BONUS   = 10    # монет каждый день
ADMIN_IDS     = {8769232009}  # ← вставьте свой Telegram user_id

# ══════════════════════════════════════════════════════
#                   🗄️  БАЗА ДАННЫХ
# ══════════════════════════════════════════════════════

DB_PATH = os.path.join(os.path.dirname(__file__), "casino.db")
_db = sqlite3.connect(DB_PATH, check_same_thread=False)
_db.row_factory = sqlite3.Row
_db.executescript("""
    CREATE TABLE IF NOT EXISTS users (
        user_id  INTEGER PRIMARY KEY,
        username TEXT NOT NULL,
        balance  INTEGER NOT NULL DEFAULT 0
    );
    CREATE TABLE IF NOT EXISTS stats (
        user_id   INTEGER PRIMARY KEY,
        games     INTEGER DEFAULT 0,
        wins      INTEGER DEFAULT 0,
        losses    INTEGER DEFAULT 0,
        total_bet INTEGER DEFAULT 0,
        total_won INTEGER DEFAULT 0
    );
    CREATE TABLE IF NOT EXISTS txlog (
        id       INTEGER PRIMARY KEY AUTOINCREMENT,
        user_id  INTEGER,
        kind     TEXT,
        amount   INTEGER,
        note     TEXT,
        ts       TEXT DEFAULT (datetime('now'))
    );
    CREATE TABLE IF NOT EXISTS daily (
        user_id    INTEGER PRIMARY KEY,
        last_claim TEXT
    );
""")
_db.commit()


def db_create_user(uid: int, name: str) -> bool:
    if _db.execute("SELECT 1 FROM users WHERE user_id=?", (uid,)).fetchone():
        return False
    _db.execute("INSERT INTO users VALUES (?,?,?)", (uid, name, WELCOME_BONUS))
    _db.execute("INSERT INTO stats (user_id) VALUES (?)", (uid,))
    _db.execute("INSERT INTO txlog (user_id,kind,amount,note) VALUES (?,?,?,?)",
                (uid, "bonus", WELCOME_BONUS, "Бонус новичка"))
    _db.commit()
    return True

def db_balance(uid: int) -> int:
    r = _db.execute("SELECT balance FROM users WHERE user_id=?", (uid,)).fetchone()
    return r["balance"] if r else 0

def db_add(uid: int, amount: int, note: str = ""):
    _db.execute("UPDATE users SET balance=balance+? WHERE user_id=?", (amount, uid))
    _db.execute("INSERT INTO txlog (user_id,kind,amount,note) VALUES (?,?,?,?)",
                (uid, "add", amount, note))
    _db.commit()

def db_sub(uid: int, amount: int, note: str = ""):
    _db.execute("UPDATE users SET balance=balance-? WHERE user_id=?", (amount, uid))
    _db.execute("INSERT INTO txlog (user_id,kind,amount,note) VALUES (?,?,?,?)",
                (uid, "sub", amount, note))
    _db.commit()

def db_stats(uid: int) -> dict:
    r = _db.execute("SELECT * FROM stats WHERE user_id=?", (uid,)).fetchone()
    return dict(r) if r else {"games":0,"wins":0,"losses":0,"total_bet":0,"total_won":0}

def db_update_stats(uid: int, bet: int, win: int, won: bool):
    _db.execute("""UPDATE stats SET
        games=games+1, wins=wins+?, losses=losses+?,
        total_bet=total_bet+?, total_won=total_won+?
        WHERE user_id=?""",
        (1 if won else 0, 0 if won else 1, bet, win, uid))
    _db.commit()

def db_leaderboard():
    return _db.execute("""SELECT u.username, u.balance, s.wins
        FROM users u JOIN stats s ON u.user_id=s.user_id
        ORDER BY u.balance DESC LIMIT 10""").fetchall()

def db_history(uid: int):
    return _db.execute("""SELECT kind,amount,note,ts FROM txlog
        WHERE user_id=? ORDER BY id DESC LIMIT 10""", (uid,)).fetchall()

def db_daily(uid: int):
    today = date.today().isoformat()
    r = _db.execute("SELECT last_claim FROM daily WHERE user_id=?", (uid,)).fetchone()
    if r and r["last_claim"] == today:
        return False, 0
    if r:
        _db.execute("UPDATE daily SET last_claim=? WHERE user_id=?", (today, uid))
    else:
        _db.execute("INSERT INTO daily VALUES (?,?)", (uid, today))
    db_add(uid, DAILY_BONUS, "Ежедневный бонус")
    return True, DAILY_BONUS

# ══════════════════════════════════════════════════════
#                   🎮  ИГРОВАЯ ЛОГИКА
# ══════════════════════════════════════════════════════

# ── Слоты ──
SLOT_SYM = ["🍒","🍋","🍇","⭐","🔔","💎","7️⃣","🃏"]
SLOT_WGT = [30,  25,  20,  12,  8,   3,   1.5, 0.5]
SLOT_PAY = {
    ("🃏","🃏","🃏"):50, ("7️⃣","7️⃣","7️⃣"):30,
    ("💎","💎","💎"):20, ("🔔","🔔","🔔"):10,
    ("⭐","⭐","⭐"):7,  ("🍇","🍇","🍇"):5,
    ("🍋","🍋","🍋"):3,  ("🍒","🍒","🍒"):2,
}
def spin_slots():
    r = random.choices(SLOT_SYM, weights=SLOT_WGT, k=3)
    m = SLOT_PAY.get(tuple(r), 0)
    if not m and r.count("🍒") >= 2: m = 1.5
    return r, m

# ── Блэкджек ──
BJ_RANKS  = ["A","2","3","4","5","6","7","8","9","10","J","Q","K"]
BJ_VALS   = {"A":11,"2":2,"3":3,"4":4,"5":5,"6":6,"7":7,"8":8,"9":9,"10":10,"J":10,"Q":10,"K":10}
BJ_SUITS  = ["♠","♥","♦","♣"]
def bj_draw():  return random.choice(BJ_RANKS), random.choice(BJ_SUITS)
def bj_score(h):
    v = sum(BJ_VALS[r] for r,_ in h)
    a = sum(1 for r,_ in h if r=="A")
    while v>21 and a: v-=10; a-=1
    return v
def bj_fmt(h, hide=False):
    if hide and len(h)>1: return f"{h[0][0]}{h[0][1]}  🎴"
    return "  ".join(f"{r}{s}" for r,s in h)

# ── Рулетка ──
ROUL_RED   = {1,3,5,7,9,12,14,16,18,19,21,23,25,27,30,32,34,36}
ROUL_BLACK = {2,4,6,8,10,11,13,15,17,20,22,24,26,28,29,31,33,35}
def roul_color(n): return "🟢" if n==0 else ("🔴" if n in ROUL_RED else "⚫")
def roul_resolve(btype, n):
    m = {"green":(n==0,14),"red":(n in ROUL_RED,2),"black":(n in ROUL_BLACK,2),
         "first":(1<=n<=12,3),"second":(13<=n<=24,3),"third":(25<=n<=36,3)}
    return m.get(btype,(False,0))
ROUL_LABELS = {"red":"🔴 Красное","black":"⚫ Чёрное","green":"🟢 Зелёное",
               "first":"1️⃣ 1–12","second":"2️⃣ 13–24","third":"3️⃣ 25–36"}

# ── Мины ──
MINES_MULT = [1.10,1.22,1.35,1.50,1.68,1.88,2.12,2.40,2.72,3.10,
              3.55,4.10,4.75,5.55,6.50,7.70,9.20,11.1,13.5,17.0]

# ══════════════════════════════════════════════════════
#                   ⌨️  КЛАВИАТУРЫ
# ══════════════════════════════════════════════════════

def kb_menu():
    b = InlineKeyboardBuilder()
    b.button(text="🎰 Слоты",    callback_data="game_slots")
    b.button(text="🎲 Кости",    callback_data="game_dice")
    b.button(text="🃏 Блэкджек", callback_data="game_blackjack")
    b.button(text="🎡 Рулетка",  callback_data="game_roulette")
    b.button(text="🪙 Монетка",  callback_data="game_coin")
    b.button(text="💣 Мины",     callback_data="game_mines")
    b.adjust(2)
    b.row(InlineKeyboardButton(text="💰 Пополнить", callback_data="deposit"),
          InlineKeyboardButton(text="💸 Вывести",   callback_data="withdraw"))
    b.row(InlineKeyboardButton(text="🎁 Бонус",     callback_data="daily"),
          InlineKeyboardButton(text="📜 История",   callback_data="history"))
    b.row(InlineKeyboardButton(text="📊 Статистика",callback_data="stats"),
          InlineKeyboardButton(text="🏆 Лидеры",    callback_data="leaders"))
    b.row(InlineKeyboardButton(text="ℹ️ Помощь",    callback_data="help"))
    return b.as_markup()

def kb_bets(game: str):
    b = InlineKeyboardBuilder()
    for a in [10,25,50,100,250,500]:
        b.button(text=f"⭐ {a}", callback_data=f"bet_{game}_{a}")
    b.adjust(3)
    b.row(InlineKeyboardButton(text="🔙 Меню", callback_data="menu"))
    return b.as_markup()

def kb_back(to="menu"):
    return InlineKeyboardMarkup(inline_keyboard=[
        [InlineKeyboardButton(text="🔙 Меню", callback_data=to)]
    ])

def bal(uid): return f"💰 Баланс: *{db_balance(uid):,} монет*"

# ══════════════════════════════════════════════════════
#                   📦  FSM STATES
# ══════════════════════════════════════════════════════

class S(StatesGroup):
    blackjack = State()
    mines     = State()
    dice_bet  = State()
    coin_bet  = State()

# ══════════════════════════════════════════════════════
#                   🤖  БОТ
# ══════════════════════════════════════════════════════

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
bot = Bot(token=BOT_TOKEN)
dp  = Dispatcher(storage=MemoryStorage())

# ── /start ──────────────────────────────────────────

@dp.message(CommandStart())
async def start(msg: types.Message):
    u    = msg.from_user
    new  = db_create_user(u.id, u.username or u.first_name)
    text = (f"🎰 *GOLDEN CROWN CASINO*\n\n"
            f"Привет, *{u.first_name}*!\n"
            f"{'🎁 Вам начислено 100 монет бонуса!\n' if new else ''}\n"
            f"{bal(u.id)}\n\nВыберите игру:")
    await msg.answer(text, reply_markup=kb_menu(), parse_mode="Markdown")

@dp.callback_query(F.data == "menu")
async def to_menu(cb: types.CallbackQuery, state: FSMContext):
    await state.clear()
    await cb.message.edit_text(
        f"🎰 *GOLDEN CROWN CASINO*\n\n{bal(cb.from_user.id)}\n\nВыберите игру:",
        reply_markup=kb_menu(), parse_mode="Markdown")

# ── Статистика ──────────────────────────────────────

@dp.callback_query(F.data == "stats")
async def show_stats(cb: types.CallbackQuery):
    s  = db_stats(cb.from_user.id)
    wr = s["wins"]/s["games"]*100 if s["games"] else 0
    pr = s["total_won"] - s["total_bet"]
    await cb.message.edit_text(
        f"📊 *Статистика*\n\n"
        f"{bal(cb.from_user.id)}\n"
        f"🎮 Игр: *{s['games']}*\n"
        f"✅ Побед: *{s['wins']}*  ❌ Поражений: *{s['losses']}*\n"
        f"📈 Винрейт: *{wr:.1f}%*\n"
        f"💵 Поставлено: *{s['total_bet']:,}*\n"
        f"🏆 Выиграно: *{s['total_won']:,}*\n"
        f"📉 Итог: *{'+' if pr>=0 else ''}{pr:,} монет*",
        reply_markup=kb_back(), parse_mode="Markdown")

# ── Лидерборд ───────────────────────────────────────

@dp.callback_query(F.data == "leaders")
async def show_leaders(cb: types.CallbackQuery):
    medals = ["🥇","🥈","🥉","4️⃣","5️⃣","6️⃣","7️⃣","8️⃣","9️⃣","🔟"]
    lines  = ["🏆 *ТОП-10*\n"]
    for i, r in enumerate(db_leaderboard()):
        lines.append(f"{medals[i]} *{r['username']}* — {r['balance']:,} монет ({r['wins']} побед)")
    await cb.message.edit_text("\n".join(lines), reply_markup=kb_back(), parse_mode="Markdown")

# ── История ─────────────────────────────────────────

@dp.callback_query(F.data == "history")
async def show_history(cb: types.CallbackQuery):
    rows  = db_history(cb.from_user.id)
    icons = {"add":"💰","sub":"🎲","bonus":"🎁"}
    lines = ["📜 *Последние операции*\n"]
    for r in rows:
        sign = "+" if r["kind"] in ("add","bonus") else "-"
        lines.append(f"{icons.get(r['kind'],'•')} `{r['ts'][:16]}` {sign}{r['amount']:,}  _{r['note'] or ''}_ ")
    if not rows: lines.append("_Пока пусто — сыграйте первую игру!_")
    await cb.message.edit_text("\n".join(lines), reply_markup=kb_back(), parse_mode="Markdown")

# ── Ежедневный бонус ────────────────────────────────

@dp.callback_query(F.data == "daily")
async def daily_bonus(cb: types.CallbackQuery):
    ok, amount = db_daily(cb.from_user.id)
    text = (f"🎁 *+{amount} монет!*\n\n{bal(cb.from_user.id)}\n\nВозвращайтесь завтра!"
            if ok else f"⏳ *Бонус уже получен сегодня*\n\n{bal(cb.from_user.id)}")
    await cb.message.edit_text(text, reply_markup=kb_back(), parse_mode="Markdown")

# ── Помощь ──────────────────────────────────────────

@dp.callback_query(F.data == "help")
async def show_help(cb: types.CallbackQuery):
    await cb.message.edit_text(
        "ℹ️ *СПРАВКА*\n\n"
        "🎰 *Слоты* — 8 символов, выплаты ×2–×50\n"
        "🎲 *Кости* — 2 кубика, больше/меньше 7 → ×1.9\n"
        "🃏 *Блэкджек* — победа ×2, блэкджек ×2.5\n"
        "🎡 *Рулетка* — цвет ×2, сектор ×3, зелёное ×14\n"
        "🪙 *Монетка* — орёл или решка → ×1.95\n"
        "💣 *Мины* — 5×5 поле, 5 мин, кэшаут в любой момент\n\n"
        "💳 *Пополнение:* ⭐ Stars или ₿ крипта\n"
        "💸 *Вывод:* от 500 монет (100 монет = 1 Star)\n"
        "🎁 Бонус новичка: 100 монет  |  Ежедневный: 50",
        reply_markup=kb_back(), parse_mode="Markdown")

# ══════════════════════════════════════════════════════
#             💰  ПОПОЛНЕНИЕ — STARS
# ══════════════════════════════════════════════════════

@dp.callback_query(F.data == "deposit")
async def show_deposit(cb: types.CallbackQuery):
    b = InlineKeyboardBuilder()
    packs = [(50,50,""),(150,175," +17%"),(500,650," +30%"),(1000,1400," +40%")]
    for stars, coins, bonus in packs:
        b.button(text=f"⭐ {stars} Stars → {coins} монет{bonus}", callback_data=f"stars_{stars}")
    b.adjust(1)
    b.row(InlineKeyboardButton(text="₿ Криптовалюта", callback_data="crypto"))
    b.row(InlineKeyboardButton(text="🔙 Меню", callback_data="menu"))
    await cb.message.edit_text(
        "💰 *ПОПОЛНЕНИЕ*\n\nВыберите пакет Stars или крипту:",
        reply_markup=b.as_markup(), parse_mode="Markdown")

@dp.callback_query(F.data.startswith("stars_"))
async def pay_stars(cb: types.CallbackQuery):
    stars = int(cb.data.split("_")[1])
    coins = {50:50,150:175,500:650,1000:1400}[stars]
    await bot.send_invoice(
        chat_id=cb.from_user.id,
        title=f"🎰 {coins} монет",
        description=f"Пополнение Golden Crown Casino на {coins} монет",
        payload=f"s|{stars}|{coins}|{cb.from_user.id}",
        currency="XTR",
        prices=[LabeledPrice(label=f"{coins} монет", amount=stars)],
        reply_markup=InlineKeyboardMarkup(inline_keyboard=[
            [InlineKeyboardButton(text=f"⭐ Оплатить {stars} Stars", pay=True)],
            [InlineKeyboardButton(text="❌ Отмена", callback_data="deposit")],
        ]))
    await cb.answer()

@dp.pre_checkout_query()
async def pre_checkout(q: PreCheckoutQuery):
    await q.answer(ok=True)

@dp.message(F.successful_payment)
async def on_paid(msg: types.Message):
    _, stars, coins, uid = msg.successful_payment.invoice_payload.split("|")
    stars, coins, uid = int(stars), int(coins), int(uid)
    db_add(uid, coins, f"Stars×{stars}")
    await msg.answer(
        f"✅ *Оплачено!*\n\n⭐ {stars} Stars → 💰 {coins} монет\n{bal(uid)}",
        reply_markup=kb_menu(), parse_mode="Markdown")

# ══════════════════════════════════════════════════════
#             ₿  ПОПОЛНЕНИЕ — КРИПТА
# ══════════════════════════════════════════════════════

@dp.callback_query(F.data == "crypto")
async def show_crypto(cb: types.CallbackQuery):
    b = InlineKeyboardBuilder()
    for coin, info in CRYPTO_INFO.items():
        b.button(text=f"{info['emoji']} {coin}", callback_data=f"c_{coin}")
    b.adjust(2)
    b.row(InlineKeyboardButton(text="🔙 Назад", callback_data="deposit"))
    await cb.message.edit_text("₿ *КРИПТА*\n\nВыберите валюту:",
                               reply_markup=b.as_markup(), parse_mode="Markdown")

@dp.callback_query(F.data.regexp(r"^c_(BTC|ETH|TON|USDT)$"))
async def crypto_select(cb: types.CallbackQuery):
    coin = cb.data[2:]
    info = CRYPTO_INFO[coin]
    wallet = CRYPTO_WALLETS[coin]
    await cb.message.edit_text(
        f"{info['emoji']} *Оплата {coin}*\n\n"
        f"📬 Адрес:\n`{wallet}`\n\n"
        f"💱 1 {coin} = {info['rate']:,} монет\n"
        f"🔻 Минимум: {info['min']} {coin}\n\n"
        f"После отправки нажмите кнопку ниже.",
        reply_markup=InlineKeyboardMarkup(inline_keyboard=[
            [InlineKeyboardButton(text="✅ Я отправил(а)", callback_data=f"cs_{coin}")],
            [InlineKeyboardButton(text="🔙 Назад", callback_data="crypto")],
        ]), parse_mode="Markdown")

@dp.callback_query(F.data.startswith("cs_"))
async def crypto_sent(cb: types.CallbackQuery):
    coin = cb.data[3:]
    await cb.message.edit_text(
        f"⏳ *Ожидание подтверждения {coin}*\n\n"
        f"Зачисление через 10–30 мин после 1 подтверждения сети.\n"
        f"ID: `{cb.from_user.id}`",
        reply_markup=kb_back(), parse_mode="Markdown")

# ══════════════════════════════════════════════════════
#             💸  ВЫВОД
# ══════════════════════════════════════════════════════

@dp.callback_query(F.data == "withdraw")
async def show_withdraw(cb: types.CallbackQuery):
    b = db_balance(cb.from_user.id)
    if b < 500:
        await cb.message.edit_text(
            f"💸 *ВЫВОД*\n\n{bal(cb.from_user.id)}\n\n❌ Нужно минимум *500 монет*.",
            reply_markup=InlineKeyboardMarkup(inline_keyboard=[
                [InlineKeyboardButton(text="💰 Пополнить", callback_data="deposit")],
                [InlineKeyboardButton(text="🔙 Меню",      callback_data="menu")],
            ]), parse_mode="Markdown")
        return
    await cb.message.edit_text(
        f"💸 *ВЫВОД*\n\n{bal(cb.from_user.id)} (~{b//100} Stars)\n\n"
        f"Курс: 100 монет = 1 Star\nКрипта от 1 000 монет",
        reply_markup=InlineKeyboardMarkup(inline_keyboard=[
            [InlineKeyboardButton(text="⭐ Вывести Stars",  callback_data="w_stars")],
            [InlineKeyboardButton(text="₿ Вывести крипту", callback_data="w_crypto")],
            [InlineKeyboardButton(text="🔙 Меню",           callback_data="menu")],
        ]), parse_mode="Markdown")

@dp.callback_query(F.data.in_({"w_stars","w_crypto"}))
async def do_withdraw(cb: types.CallbackQuery):
    m = "Stars" if cb.data == "w_stars" else "крипту"
    await cb.message.edit_text(
        f"📤 *Вывод через {m}*\n\nНапишите в поддержку: @GoldenCrownSupport\n\n"
        f"Укажите ID: `{cb.from_user.id}`, сумму и реквизиты.\n⏱ 24–48 ч.",
        reply_markup=kb_back(), parse_mode="Markdown")

# ══════════════════════════════════════════════════════
#                   🎰  СЛОТЫ
# ══════════════════════════════════════════════════════

@dp.callback_query(F.data == "game_slots")
async def g_slots(cb: types.CallbackQuery):
    await cb.message.edit_text(
        f"🎰 *СЛОТЫ*\n\n{bal(cb.from_user.id)}\n\n"
        "🃏×50  7️⃣×30  💎×20  🔔×10  ⭐×7\n"
        "🍇×5   🍋×3   🍒×2   🍒🍒×1.5\n\nСтавка:",
        reply_markup=kb_bets("slots"), parse_mode="Markdown")

@dp.callback_query(F.data.startswith("bet_slots_"))
async def play_slots(cb: types.CallbackQuery):
    bet = int(cb.data.split("_")[2]); uid = cb.from_user.id
    if db_balance(uid) < bet: await cb.answer("❌ Недостаточно монет!",show_alert=True); return
    await cb.answer("🎰 Крутим…")
    reels, mult = spin_slots()
    win = int(bet * mult) if mult else 0
    db_sub(uid, bet, "Слоты")
    if win: db_add(uid, win, "Слоты: выигрыш")
    db_update_stats(uid, bet, win, win>0)
    badge = ("🎊 *ДЖЕКПОТ!*" if mult>=20 else "🎉 *БОЛЬШОЙ ВЫИГРЫШ!*" if mult>=10
             else "✅ *Выигрыш!*") + f" ×{mult}" if win else "❌ *Не повезло…*"
    profit = win-bet
    b = InlineKeyboardBuilder()
    for a in [bet,25,50,100]: b.button(text=f"⭐{a}", callback_data=f"bet_slots_{a}")
    b.adjust(4); b.row(InlineKeyboardButton(text="🔙 Меню", callback_data="menu"))
    await cb.message.edit_text(
        f"🎰 *СЛОТЫ*\n\n`[ {reels[0]} | {reels[1]} | {reels[2]} ]`\n\n"
        f"{badge}\n💵 {'+' if profit>=0 else ''}{profit:,} монет\n{bal(uid)}",
        reply_markup=b.as_markup(), parse_mode="Markdown")

# ══════════════════════════════════════════════════════
#                   🎲  КОСТИ
# ══════════════════════════════════════════════════════

@dp.callback_query(F.data == "game_dice")
async def g_dice(cb: types.CallbackQuery):
    await cb.message.edit_text(
        f"🎲 *КОСТИ*\n\n{bal(cb.from_user.id)}\n\n"
        "2 кубика. Сумма больше или меньше 7? Ровно 7 = ничья. Победа ×1.9\n\nСтавка:",
        reply_markup=kb_bets("dice"), parse_mode="Markdown")

@dp.callback_query(F.data.startswith("bet_dice_"))
async def dice_pick(cb: types.CallbackQuery, state: FSMContext):
    bet = int(cb.data.split("_")[2])
    if db_balance(cb.from_user.id) < bet: await cb.answer("❌ Недостаточно монет!",show_alert=True); return
    await state.update_data(dice_bet=bet)
    await cb.message.edit_text(
        f"🎲 Ставка: *{bet}*\n\nВаш прогноз?",
        reply_markup=InlineKeyboardMarkup(inline_keyboard=[
            [InlineKeyboardButton(text="📈 Больше 7", callback_data="dice_hi"),
             InlineKeyboardButton(text="📉 Меньше 7", callback_data="dice_lo")],
            [InlineKeyboardButton(text="🔙 Назад", callback_data="game_dice")],
        ]), parse_mode="Markdown")

@dp.callback_query(F.data.in_({"dice_hi","dice_lo"}))
async def dice_resolve(cb: types.CallbackQuery, state: FSMContext):
    data = await state.get_data(); bet = data.get("dice_bet",50); uid = cb.from_user.id
    d1,d2 = random.randint(1,6), random.randint(1,6); total = d1+d2
    F6 = ["","1️⃣","2️⃣","3️⃣","4️⃣","5️⃣","6️⃣"]
    db_sub(uid, bet, "Кости")
    if total==7:        win=bet;         badge="⚖️ *Ничья!*"
    elif (cb.data=="dice_hi" and total>7) or (cb.data=="dice_lo" and total<7):
                         win=int(bet*1.9); badge="✅ *Угадали!*"
    else:                win=0;           badge="❌ *Не угадали*"
    if win: db_add(uid, win, "Кости: выигрыш")
    db_update_stats(uid, bet, win, win>bet); await state.clear()
    profit=win-bet
    await cb.message.edit_text(
        f"🎲 *КОСТИ*\n\n{F6[d1]} + {F6[d2]} = *{total}*\n\n"
        f"{badge}\n💵 {'+' if profit>=0 else ''}{profit:,} монет\n{bal(uid)}",
        reply_markup=InlineKeyboardMarkup(inline_keyboard=[
            [InlineKeyboardButton(text="🎲 Ещё раз",callback_data="game_dice")],
            [InlineKeyboardButton(text="🔙 Меню",   callback_data="menu")],
        ]), parse_mode="Markdown")

# ══════════════════════════════════════════════════════
#                   🃏  БЛЭКДЖЕК
# ══════════════════════════════════════════════════════

def _bj_text(player, dealer, bet, hide=True):
    pv = bj_score(player)
    return (f"🃏 *БЛЭКДЖЕК* | Ставка: {bet}\n\n"
            f"🎩 Дилер: {bj_fmt(dealer,hide)}\n\n"
            f"🤚 Вы: {bj_fmt(player)} = *{pv}*\n\n")

async def _bj_finish(cb, state, reason):
    d = await state.get_data()
    p,dealer,bet = d["p"],d["dealer"],d["bet"]; uid = cb.from_user.id
    while bj_score(dealer)<17: dealer.append(bj_draw())
    pv,dv = bj_score(p), bj_score(dealer)
    db_sub(uid, bet, "БЖ")
    if reason=="bj":      win=int(bet*2.5); badge=f"🃏 *БЛЭКДЖЕК ×2.5!* +{win-bet:,}"
    elif pv>21:           win=0;            badge=f"💥 *Перебор!* -{bet:,}"
    elif dv>21 or pv>dv:  win=bet*2;        badge=f"✅ *Победа ×2!* +{bet:,}"
    elif pv==dv:          win=bet;           badge="⚖️ *Ничья*"
    else:                 win=0;            badge=f"❌ *Дилер победил* -{bet:,}"
    if win: db_add(uid, win, "БЖ: выигрыш")
    db_update_stats(uid, bet, win, win>bet); await state.clear()
    await cb.message.edit_text(
        f"🃏 *БЛЭКДЖЕК*\n\n"
        f"🎩 Дилер: {bj_fmt(dealer)} = *{dv}*\n"
        f"🤚 Вы:    {bj_fmt(p)} = *{pv}*\n\n"
        f"{badge}\n{bal(uid)}",
        reply_markup=InlineKeyboardMarkup(inline_keyboard=[
            [InlineKeyboardButton(text="🃏 Ещё раз",callback_data="game_blackjack")],
            [InlineKeyboardButton(text="🔙 Меню",   callback_data="menu")],
        ]), parse_mode="Markdown")

@dp.callback_query(F.data == "game_blackjack")
async def g_bj(cb: types.CallbackQuery):
    await cb.message.edit_text(
        f"🃏 *БЛЭКДЖЕК*\n\n{bal(cb.from_user.id)}\n\n"
        "Победа ×2  |  Блэкджек ×2.5  |  Удвоение доступно\n\nСтавка:",
        reply_markup=kb_bets("bj"), parse_mode="Markdown")

@dp.callback_query(F.data.startswith("bet_bj_"))
async def bj_start(cb: types.CallbackQuery, state: FSMContext):
    bet = int(cb.data.split("_")[2]); uid = cb.from_user.id
    if db_balance(uid)<bet: await cb.answer("❌ Недостаточно монет!",show_alert=True); return
    p,dealer = [bj_draw(),bj_draw()],[bj_draw(),bj_draw()]
    await state.set_state(S.blackjack); await state.update_data(p=p,dealer=dealer,bet=bet)
    if bj_score(p)==21:
        await cb.message.edit_text(_bj_text(p,dealer,bet)+"🃏 *БЛЭКДЖЕК!*",parse_mode="Markdown")
        await _bj_finish(cb,state,"bj"); return
    bj_kb = InlineKeyboardMarkup(inline_keyboard=[[
        InlineKeyboardButton(text="✅ Ещё карту", callback_data="bj_hit"),
        InlineKeyboardButton(text="🛑 Хватит",   callback_data="bj_stand"),
        InlineKeyboardButton(text="💰 Удвоить",  callback_data="bj_double"),
    ]])
    await cb.message.edit_text(_bj_text(p,dealer,bet)+"Ваш ход:", reply_markup=bj_kb, parse_mode="Markdown")

@dp.callback_query(F.data=="bj_hit", S.blackjack)
async def bj_hit(cb: types.CallbackQuery, state: FSMContext):
    d=await state.get_data(); p=d["p"]; p.append(bj_draw()); await state.update_data(p=p)
    if bj_score(p)>21: await _bj_finish(cb,state,"bust"); return
    bj_kb = InlineKeyboardMarkup(inline_keyboard=[[
        InlineKeyboardButton(text="✅ Ещё", callback_data="bj_hit"),
        InlineKeyboardButton(text="🛑 Стоп",callback_data="bj_stand"),
        InlineKeyboardButton(text="💰 x2", callback_data="bj_double"),
    ]])
    await cb.message.edit_text(_bj_text(p,d["dealer"],d["bet"])+"Ваш ход:",reply_markup=bj_kb,parse_mode="Markdown")

@dp.callback_query(F.data=="bj_stand", S.blackjack)
async def bj_stand(cb: types.CallbackQuery, state: FSMContext):
    await _bj_finish(cb,state,"stand")

@dp.callback_query(F.data=="bj_double", S.blackjack)
async def bj_double(cb: types.CallbackQuery, state: FSMContext):
    d=await state.get_data(); uid=cb.from_user.id
    if db_balance(uid)<d["bet"]: await cb.answer("❌ Не хватает монет!",show_alert=True); return
    p=d["p"]; p.append(bj_draw())
    await state.update_data(p=p, bet=d["bet"]*2)
    await _bj_finish(cb,state,"stand")

# ══════════════════════════════════════════════════════
#                   🎡  РУЛЕТКА
# ══════════════════════════════════════════════════════

@dp.callback_query(F.data == "game_roulette")
async def g_roulette(cb: types.CallbackQuery):
    b = InlineKeyboardBuilder()
    b.button(text="🔴 Красное ×2",  callback_data="rt_red")
    b.button(text="⚫ Чёрное ×2",  callback_data="rt_black")
    b.button(text="🟢 Зелёное ×14",callback_data="rt_green")
    b.button(text="1️⃣ 1–12 ×3",   callback_data="rt_first")
    b.button(text="2️⃣ 13–24 ×3",  callback_data="rt_second")
    b.button(text="3️⃣ 25–36 ×3",  callback_data="rt_third")
    b.adjust(2); b.row(InlineKeyboardButton(text="🔙 Меню",callback_data="menu"))
    await cb.message.edit_text(f"🎡 *РУЛЕТКА*\n\n{bal(cb.from_user.id)}\n\nВыберите ставку:",
                               reply_markup=b.as_markup(), parse_mode="Markdown")

@dp.callback_query(F.data.regexp(r"^rt_(red|black|green|first|second|third)$"))
async def roulette_amount(cb: types.CallbackQuery, state: FSMContext):
    bt = cb.data[3:]; await state.update_data(rt=bt)
    b = InlineKeyboardBuilder()
    for a in [10,25,50,100,250,500]: b.button(text=f"⭐{a}", callback_data=f"rb_{bt}_{a}")
    b.adjust(3); b.row(InlineKeyboardButton(text="🔙 Назад",callback_data="game_roulette"))
    await cb.message.edit_text(
        f"🎡 Ставка на *{ROUL_LABELS[bt]}*\n{bal(cb.from_user.id)}\n\nСумма:",
        reply_markup=b.as_markup(), parse_mode="Markdown")

@dp.callback_query(F.data.startswith("rb_"))
async def roulette_play(cb: types.CallbackQuery, state: FSMContext):
    _,bt,bets = cb.data.split("_",2); bet=int(bets); uid=cb.from_user.id
    if db_balance(uid)<bet: await cb.answer("❌ Недостаточно монет!",show_alert=True); return
    await cb.answer("🎡 Крутится…")
    n=random.randint(0,36); won,mult=roul_resolve(bt,n)
    db_sub(uid,bet,"Рулетка"); win=int(bet*mult) if won else 0
    if win: db_add(uid,win,"Рулетка: выигрыш")
    db_update_stats(uid,bet,win,won); await state.clear()
    profit=win-bet
    await cb.message.edit_text(
        f"🎡 *РУЛЕТКА*\n\nВыпало: {roul_color(n)} *{n}*\nСтавка: *{ROUL_LABELS[bt]}*\n\n"
        f"{'✅ *Выигрыш!*' if won else '❌ *Проигрыш*'}\n"
        f"💵 {'+' if profit>=0 else ''}{profit:,} монет\n{bal(uid)}",
        reply_markup=InlineKeyboardMarkup(inline_keyboard=[
            [InlineKeyboardButton(text="🎡 Ещё раз",callback_data="game_roulette")],
            [InlineKeyboardButton(text="🔙 Меню",   callback_data="menu")],
        ]), parse_mode="Markdown")

# ══════════════════════════════════════════════════════
#                   🪙  МОНЕТКА
# ══════════════════════════════════════════════════════

@dp.callback_query(F.data == "game_coin")
async def g_coin(cb: types.CallbackQuery):
    await cb.message.edit_text(
        f"🪙 *МОНЕТКА*\n\n{bal(cb.from_user.id)}\n\nОрёл или решка? ×1.95\n\nСтавка:",
        reply_markup=kb_bets("coin"), parse_mode="Markdown")

@dp.callback_query(F.data.startswith("bet_coin_"))
async def coin_pick(cb: types.CallbackQuery, state: FSMContext):
    bet=int(cb.data.split("_")[2])
    if db_balance(cb.from_user.id)<bet: await cb.answer("❌ Недостаточно монет!",show_alert=True); return
    await state.update_data(coin_bet=bet)
    await cb.message.edit_text(
        f"🪙 Ставка: *{bet}*\n\nОрёл или решка?",
        reply_markup=InlineKeyboardMarkup(inline_keyboard=[
            [InlineKeyboardButton(text="🦅 Орёл", callback_data="coin_h"),
             InlineKeyboardButton(text="🏛 Решка",callback_data="coin_t")],
            [InlineKeyboardButton(text="🔙 Назад",callback_data="game_coin")],
        ]), parse_mode="Markdown")

@dp.callback_query(F.data.in_({"coin_h","coin_t"}))
async def coin_play(cb: types.CallbackQuery, state: FSMContext):
    d=await state.get_data(); bet=d.get("coin_bet",50); uid=cb.from_user.id
    res=random.choice(["coin_h","coin_t"]); won=res==cb.data
    db_sub(uid,bet,"Монетка"); win=int(bet*1.95) if won else 0
    if win: db_add(uid,win,"Монетка: выигрыш")
    db_update_stats(uid,bet,win,won); await state.clear()
    profit=win-bet; emoji="🦅" if res=="coin_h" else "🏛"; name="Орёл" if res=="coin_h" else "Решка"
    await cb.message.edit_text(
        f"🪙 *МОНЕТКА*\n\nВыпало: {emoji} *{name}*\n\n"
        f"{'✅ *Угадали!*' if won else '❌ *Не угадали*'}\n"
        f"💵 {'+' if profit>=0 else ''}{profit:,} монет\n{bal(uid)}",
        reply_markup=InlineKeyboardMarkup(inline_keyboard=[
            [InlineKeyboardButton(text="🪙 Ещё раз",callback_data="game_coin")],
            [InlineKeyboardButton(text="🔙 Меню",   callback_data="menu")],
        ]), parse_mode="Markdown")

# ══════════════════════════════════════════════════════
#                   💣  МИНЫ
# ══════════════════════════════════════════════════════

def mines_kb(revealed, mines, over=False):
    b = InlineKeyboardBuilder()
    for i in range(25):
        if i in revealed:
            b.button(text="💥" if i in mines else "💎", callback_data=f"m_x_{i}")
        elif over and i in mines:
            b.button(text="💣", callback_data=f"m_x_{i}")
        else:
            b.button(text="⬛", callback_data=f"m_{i}")
    b.adjust(5)
    if not over:
        b.row(InlineKeyboardButton(text="💸 Забрать", callback_data="m_cash"),
              InlineKeyboardButton(text="🏳 Сдаться", callback_data="m_quit"))
    else:
        b.row(InlineKeyboardButton(text="🔙 Меню", callback_data="menu"))
    return b.as_markup()

@dp.callback_query(F.data == "game_mines")
async def g_mines(cb: types.CallbackQuery):
    await cb.message.edit_text(
        f"💣 *МИНЫ*\n\n{bal(cb.from_user.id)}\n\n"
        "Поле 5×5, 5 мин 💣. Открывайте клетки и забирайте выигрыш!\n\nСтавка:",
        reply_markup=kb_bets("mines"), parse_mode="Markdown")

@dp.callback_query(F.data.startswith("bet_mines_"))
async def mines_start(cb: types.CallbackQuery, state: FSMContext):
    bet=int(cb.data.split("_")[2]); uid=cb.from_user.id
    if db_balance(uid)<bet: await cb.answer("❌ Недостаточно монет!",show_alert=True); return
    mines=random.sample(range(25),5)
    await state.set_state(S.mines); await state.update_data(bet=bet,mines=mines,rev=[],step=0)
    await cb.message.edit_text(
        f"💣 *МИНЫ* | Ставка: {bet}\n\nМножитель: ×1.0  →  *{bet:,} монет*",
        reply_markup=mines_kb([],mines), parse_mode="Markdown")

@dp.callback_query(F.data.regexp(r"^m_\d+$"), S.mines)
async def mines_click(cb: types.CallbackQuery, state: FSMContext):
    idx=int(cb.data[2:]); d=await state.get_data()
    mines,rev,bet,step = d["mines"],d["rev"],d["bet"],d["step"]; uid=cb.from_user.id
    if idx in rev: await cb.answer("Уже открыто!"); return
    rev.append(idx)
    if idx in mines:
        db_sub(uid,bet,"Мины: взрыв"); db_update_stats(uid,bet,0,False); await state.clear()
        await cb.message.edit_text(
            f"💥 *БУМ!*\n\n❌ -{bet:,} монет\n{bal(uid)}",
            reply_markup=InlineKeyboardMarkup(inline_keyboard=[
                [InlineKeyboardButton(text="💣 Ещё раз",callback_data="game_mines")],
                [InlineKeyboardButton(text="🔙 Меню",   callback_data="menu")],
            ]), parse_mode="Markdown")
        return
    step=min(step+1,len(MINES_MULT)-1); mult=MINES_MULT[step]
    await state.update_data(rev=rev,step=step)
    await cb.message.edit_text(
        f"💣 *МИНЫ* | Ставка: {bet}\n\n💎 Множитель: ×{mult}\n"
        f"Потенциально: *{int(bet*mult):,} монет*",
        reply_markup=mines_kb(rev,mines), parse_mode="Markdown")

@dp.callback_query(F.data=="m_cash", S.mines)
async def mines_cash(cb: types.CallbackQuery, state: FSMContext):
    d=await state.get_data(); bet,step,uid=d["bet"],d["step"],cb.from_user.id
    if step==0: await cb.answer("Откройте хотя бы одну клетку!",show_alert=True); return
    mult=MINES_MULT[step]; win=int(bet*mult)
    db_sub(uid,bet,"Мины"); db_add(uid,win,"Мины: кэшаут")
    db_update_stats(uid,bet,win,True); await state.clear()
    await cb.message.edit_text(
        f"💸 *КЭШАУТ!*\n\n×{mult} → +{win-bet:,} монет\n{bal(uid)}",
        reply_markup=InlineKeyboardMarkup(inline_keyboard=[
            [InlineKeyboardButton(text="💣 Ещё раз",callback_data="game_mines")],
            [InlineKeyboardButton(text="🔙 Меню",   callback_data="menu")],
        ]), parse_mode="Markdown")

@dp.callback_query(F.data=="m_quit", S.mines)
async def mines_quit(cb: types.CallbackQuery, state: FSMContext):
    d=await state.get_data(); bet=d["bet"]; uid=cb.from_user.id
    db_sub(uid,bet,"Мины: сдался"); db_update_stats(uid,bet,0,False); await state.clear()
    await cb.message.edit_text(
        f"🏳 *Сдались.*\n\n❌ -{bet:,} монет\n{bal(uid)}",
        reply_markup=kb_back(), parse_mode="Markdown")

# ══════════════════════════════════════════════════════
#                   🔧  АДМИН
# ══════════════════════════════════════════════════════

@dp.message(Command("admin"))
async def cmd_admin(msg: types.Message):
    if msg.from_user.id not in ADMIN_IDS: return
    total = _db.execute("SELECT COUNT(*) FROM users").fetchone()[0]
    bets  = _db.execute("SELECT SUM(total_bet) FROM stats").fetchone()[0] or 0
    await msg.answer(f"🔧 *Админ*\n\n👥 Пользователей: {total}\n💵 Поставлено: {bets:,} монет",
                     parse_mode="Markdown")

@dp.message(Command("give"))
async def cmd_give(msg: types.Message):
    """/give <user_id> <сумма>"""
    if msg.from_user.id not in ADMIN_IDS: return
    try:
        _, uid, amount = msg.text.split()
        db_add(int(uid), int(amount), "Начислено администратором")
        await msg.answer(f"✅ Начислено {amount} монет → {uid}")
    except Exception as e:
        await msg.answer(f"❌ {e}\nФормат: /give <user_id> <сумма>")

# ══════════════════════════════════════════════════════

async def main():
    logging.info("🎰 Golden Crown Casino Bot запущен!")
    await dp.start_polling(bot, skip_updates=True)

if __name__ == "__main__":
    asyncio.run(main())
