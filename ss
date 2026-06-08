#!/usr/bin/env python3
import logging
import random
import asyncio
from aiogram import Bot, Dispatcher, types, F
from aiogram.filters import CommandStart
from aiogram.types import InlineKeyboardMarkup, InlineKeyboardButton
from aiogram.fsm.storage.memory import MemoryStorage
from aiogram.fsm.context import FSMContext
from aiogram.fsm.state import State, StatesGroup
from aiogram.utils.keyboard import InlineKeyboardBuilder

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

BOT_TOKEN = "8970836944:AAHhycv65QScpbCB3gqFkuCTiSxaBLfQ1Y0"

# ===== БОТ (БЕЗ ПРОКСИ - просто включите VPN) =====
bot = Bot(token=BOT_TOKEN)
dp = Dispatcher(storage=MemoryStorage())

# ===== БАЗА ДАННЫХ =====
users = {}

def get_balance(user_id):
    return users.get(user_id, {}).get('balance', 0)

def add_balance(user_id, amount):
    if user_id not in users:
        users[user_id] = {'balance': 100, 'username': str(user_id), 'wins': 0, 'games': 0}
    users[user_id]['balance'] += amount

def sub_balance(user_id, amount):
    if user_id in users:
        users[user_id]['balance'] -= amount

# ===== КНОПКИ =====
def main_menu():
    kb = InlineKeyboardBuilder()
    kb.button(text="🎰 Слоты", callback_data="slots")
    kb.button(text="🎲 Кости", callback_data="dice")
    kb.button(text="🎡 Рулетка", callback_data="roulette")
    kb.button(text="🪙 Монетка", callback_data="coin")
    kb.adjust(2)
    kb.row(InlineKeyboardButton(text="💰 Баланс", callback_data="balance"))
    kb.row(InlineKeyboardButton(text="ℹ️ Помощь", callback_data="help"))
    return kb.as_markup()

def bet_kb(game):
    kb = InlineKeyboardBuilder()
    for a in [10, 25, 50, 100]:
        kb.button(text=f"{a}⭐", callback_data=f"bet_{game}_{a}")
    kb.adjust(2)
    kb.row(InlineKeyboardButton(text="🔙 Назад", callback_data="back"))
    return kb.as_markup()

def roulette_kb():
    kb = InlineKeyboardBuilder()
    kb.button(text="🔴 Красное (x2)", callback_data="r_red")
    kb.button(text="⚫ Чёрное (x2)", callback_data="r_black")
    kb.button(text="🟢 Зелёное (x14)", callback_data="r_green")
    kb.button(text="1-12 (x3)", callback_data="r_1")
    kb.button(text="13-24 (x3)", callback_data="r_2")
    kb.button(text="25-36 (x3)", callback_data="r_3")
    kb.adjust(2)
    kb.row(InlineKeyboardButton(text="🔙 Назад", callback_data="back"))
    return kb.as_markup()

# ===== ЛОГИКА ИГР =====
def slots():
    symbols = ["🍒", "🍋", "🍇", "⭐", "🔔", "💎", "7️⃣", "🃏"]
    weights = [30, 25, 20, 12, 8, 3, 2, 1]
    res = random.choices(symbols, weights=weights, k=3)
    pays = {("🃏","🃏","🃏"):50, ("7️⃣","7️⃣","7️⃣"):30, ("💎","💎","💎"):20,
            ("🔔","🔔","🔔"):10, ("⭐","⭐","⭐"):7, ("🍇","🍇","🍇"):5,
            ("🍋","🍋","🍋"):3, ("🍒","🍒","🍒"):2}
    mult = pays.get(tuple(res), 0)
    if res.count("🍒") == 2:
        mult = 1.5
    return res, mult

roulette_red = {1,3,5,7,9,12,14,16,18,19,21,23,25,27,30,32,34,36}
roulette_black = {2,4,6,8,10,11,13,15,17,20,22,24,26,28,29,31,33,35}

class States(StatesGroup):
    dice = State()
    roulette = State()
    coin = State()

# ===== ОБРАБОТЧИКИ =====
@dp.message(CommandStart())
async def start(m: types.Message):
    user = m.from_user
    if user.id not in users:
        users[user.id] = {'balance': 100, 'username': user.first_name, 'wins': 0, 'games': 0}
    await m.answer(
        f"🎰 *КАЗИНО* 🎰\n\nПривет, {user.first_name}!\n💰 Баланс: {get_balance(user.id)} монет\n\nВыбери игру:",
        reply_markup=main_menu(), parse_mode="Markdown"
    )

@dp.callback_query(F.data == "back")
async def back(c: types.CallbackQuery, state: FSMContext):
    await state.clear()
    await c.message.edit_text(
        f"🎰 *КАЗИНО*\n\n💰 Баланс: {get_balance(c.from_user.id)} монет",
        reply_markup=main_menu(), parse_mode="Markdown"
    )

@dp.callback_query(F.data == "balance")
async def show_balance(c: types.CallbackQuery):
    await c.answer(f"💰 Баланс: {get_balance(c.from_user.id)} монет", show_alert=True)

@dp.callback_query(F.data == "help")
async def help_cmd(c: types.CallbackQuery):
    text = "🎰 Слоты - x2 до x50\n🎲 Кости - угадай >7 или <7 (x1.9)\n🎡 Рулетка - цвет (x2) или сектор (x3/x14)\n🪙 Монетка - орёл/решка (x1.95)"
    await c.answer(text, show_alert=True)

# ===== СЛОТЫ =====
@dp.callback_query(F.data == "slots")
async def slots_menu(c: types.CallbackQuery):
    await c.message.edit_text(
        f"🎰 *СЛОТЫ*\n💰 Баланс: {get_balance(c.from_user.id)} монет\n\nСтавка:",
        reply_markup=bet_kb("slots"), parse_mode="Markdown"
    )

@dp.callback_query(F.data.startswith("bet_slots_"))
async def play_slots(c: types.CallbackQuery):
    bet = int(c.data.split("_")[2])
    uid = c.from_user.id
    if get_balance(uid) < bet:
        await c.answer("❌ Нет денег!", show_alert=True)
        return
    res, mult = slots()
    win = int(bet * mult) if mult > 0 else 0
    sub_balance(uid, bet)
    if win:
        add_balance(uid, win)
    text = f"🎰 *СЛОТЫ*\n\n[ {res[0]} | {res[1]} | {res[2]} ]\n\n"
    text += f"✅ +{win}" if win else f"❌ -{bet}"
    text += f"\n💰 Баланс: {get_balance(uid)} монет"
    await c.message.edit_text(text, reply_markup=bet_kb("slots"), parse_mode="Markdown")

# ===== КОСТИ =====
@dp.callback_query(F.data == "dice")
async def dice_menu(c: types.CallbackQuery):
    await c.message.edit_text(
        f"🎲 *КОСТИ*\n💰 Баланс: {get_balance(c.from_user.id)} монет\n\nСтавка:",
        reply_markup=bet_kb("dice"), parse_mode="Markdown"
    )

@dp.callback_query(F.data.startswith("bet_dice_"))
async def dice_bet(c: types.CallbackQuery, state: FSMContext):
    bet = int(c.data.split("_")[2])
    if get_balance(c.from_user.id) < bet:
        await c.answer("❌ Нет денег!", show_alert=True)
        return
    await state.update_data(bet=bet)
    await state.set_state(States.dice)
    kb = InlineKeyboardMarkup(inline_keyboard=[
        [InlineKeyboardButton(text="📈 Больше 7", callback_data="dice_high"),
         InlineKeyboardButton(text="📉 Меньше 7", callback_data="dice_low")]
    ])
    await c.message.edit_text(f"🎲 Ставка: {bet}\n\nВаш выбор?", reply_markup=kb, parse_mode="Markdown")

@dp.callback_query(States.dice, F.data.in_(["dice_high", "dice_low"]))
async def dice_result(c: types.CallbackQuery, state: FSMContext):
    data = await state.get_data()
    bet = data.get("bet", 50)
    uid = c.from_user.id
    d1, d2 = random.randint(1,6), random.randint(1,6)
    total = d1 + d2
    sub_balance(uid, bet)
    win = 0
    if total == 7:
        win = bet
        res_text = "⚖️ Ничья"
    elif (c.data == "dice_high" and total > 7) or (c.data == "dice_low" and total < 7):
        win = int(bet * 1.9)
        res_text = "✅ Победа!"
    else:
        res_text = "❌ Проигрыш"
    if win:
        add_balance(uid, win)
    await state.clear()
    await c.message.edit_text(
        f"🎲 *КОСТИ*\n\n{d1} + {d2} = {total}\n\n{res_text}\n💰 Баланс: {get_balance(uid)} монет",
        reply_markup=InlineKeyboardMarkup(inline_keyboard=[[InlineKeyboardButton(text="🎲 Ещё", callback_data="dice")]]),
        parse_mode="Markdown"
    )

# ===== РУЛЕТКА =====
@dp.callback_query(F.data == "roulette")
async def roulette_menu(c: types.CallbackQuery):
    await c.message.edit_text(
        f"🎡 *РУЛЕТКА*\n💰 Баланс: {get_balance(c.from_user.id)} монет\n\nВыбери тип ставки:",
        reply_markup=roulette_kb(), parse_mode="Markdown"
    )

@dp.callback_query(F.data.startswith("r_"))
async def roulette_bet(c: types.CallbackQuery, state: FSMContext):
    bet_type = c.data.replace("r_", "")
    await state.update_data(r_type=bet_type)
    await state.set_state(States.roulette)
    kb = InlineKeyboardBuilder()
    for a in [10, 25, 50, 100]:
        kb.button(text=f"{a}⭐", callback_data=f"rbet_{bet_type}_{a}")
    kb.adjust(2)
    kb.row(InlineKeyboardButton(text="🔙 Назад", callback_data="roulette"))
    await c.message.edit_text(f"🎡 Ставка: {bet_type}\n\nСумма?", reply_markup=kb.as_markup(), parse_mode="Markdown")

@dp.callback_query(States.roulette, F.data.startswith("rbet_"))
async def roulette_result(c: types.CallbackQuery, state: FSMContext):
    parts = c.data.split("_")
    bet_type = parts[1]
    bet = int(parts[2])
    uid = c.from_user.id
    if get_balance(uid) < bet:
        await c.answer("❌ Нет денег!", show_alert=True)
        return
    num = random.randint(0, 36)
    color = "🟢" if num == 0 else ("🔴" if num in roulette_red else "⚫")
    won = False
    mult = 0
    if bet_type == "green" and num == 0:
        won, mult = True, 14
    elif bet_type == "red" and num in roulette_red:
        won, mult = True, 2
    elif bet_type == "black" and num in roulette_black:
        won, mult = True, 2
    elif bet_type == "1" and 1 <= num <= 12:
        won, mult = True, 3
    elif bet_type == "2" and 13 <= num <= 24:
        won, mult = True, 3
    elif bet_type == "3" and 25 <= num <= 36:
        won, mult = True, 3
    sub_balance(uid, bet)
    win = int(bet * mult) if won else 0
    if win:
        add_balance(uid, win)
    await state.clear()
    await c.message.edit_text(
        f"🎡 *РУЛЕТКА*\n\nВыпало: {color} {num}\n\n{'✅ +' + str(win) if won else '❌ -' + str(bet)}\n💰 Баланс: {get_balance(uid)} монет",
        reply_markup=InlineKeyboardMarkup(inline_keyboard=[[InlineKeyboardButton(text="🎡 Ещё", callback_data="roulette")]]),
        parse_mode="Markdown"
    )

# ===== МОНЕТКА =====
@dp.callback_query(F.data == "coin")
async def coin_menu(c: types.CallbackQuery):
    await c.message.edit_text(
        f"🪙 *МОНЕТКА*\n💰 Баланс: {get_balance(c.from_user.id)} монет\n\nСтавка:",
        reply_markup=bet_kb("coin"), parse_mode="Markdown"
    )

@dp.callback_query(F.data.startswith("bet_coin_"))
async def coin_bet(c: types.CallbackQuery, state: FSMContext):
    bet = int(c.data.split("_")[2])
    if get_balance(c.from_user.id) < bet:
        await c.answer("❌ Нет денег!", show_alert=True)
        return
    await state.update_data(bet=bet)
    await state.set_state(States.coin)
    kb = InlineKeyboardMarkup(inline_keyboard=[
        [InlineKeyboardButton(text="🦅 Орёл", callback_data="coin_heads"),
         InlineKeyboardButton(text="🏛 Решка", callback_data="coin_tails")]
    ])
    await c.message.edit_text(f"🪙 Ставка: {bet}\n\nОрёл или решка?", reply_markup=kb, parse_mode="Markdown")

@dp.callback_query(States.coin, F.data.in_(["coin_heads", "coin_tails"]))
async def coin_result(c: types.CallbackQuery, state: FSMContext):
    data = await state.get_data()
    bet = data.get("bet", 50)
    uid = c.from_user.id
    res = random.choice(["coin_heads", "coin_tails"])
    won = res == c.data
    sub_balance(uid, bet)
    win = int(bet * 1.95) if won else 0
    if win:
        add_balance(uid, win)
    await state.clear()
    result_name = "Орёл 🦅" if res == "coin_heads" else "Решка 🏛"
    await c.message.edit_text(
        f"🪙 *МОНЕТКА*\n\nВыпало: {result_name}\n\n{'✅ +' + str(win) if won else '❌ -' + str(bet)}\n💰 Баланс: {get_balance(uid)} монет",
        reply_markup=InlineKeyboardMarkup(inline_keyboard=[[InlineKeyboardButton(text="🪙 Ещё", callback_data="coin")]]),
        parse_mode="Markdown"
    )

# ===== ЗАПУСК =====
async def main():
    print("🤖 Бот запущен... ВКЛЮЧИТЕ VPN если не подключается!")
    await dp.start_polling(bot)

if __name__ == "__main__":
    asyncio.run(main())
