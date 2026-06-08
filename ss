#!/usr/bin/env python3
"""
🎰 GOLDEN CROWN CASINO BOT
Telegram Casino Bot with Stars & Crypto payments
"""

import logging
import random
import asyncio
from aiogram import Bot, Dispatcher, types, F
from aiogram.filters import CommandStart
from aiogram.types import (
    InlineKeyboardMarkup, InlineKeyboardButton,
    LabeledPrice, PreCheckoutQuery
)
from aiogram.fsm.storage.memory import MemoryStorage
from aiogram.fsm.context import FSMContext
from aiogram.fsm.state import State, StatesGroup
from aiogram.utils.keyboard import InlineKeyboardBuilder

logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(name)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)

# ===== НАСТРОЙКИ =====
BOT_TOKEN = "8970836944:AAHhycv65QScpbCB3gqFkuCTiSxaBLfQ1Y0"  # ВСТАВЬТЕ СВОЙ ТОКЕН!

CRYPTO_WALLET = {
    "BTC": "1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa",
    "ETH": "0x742d35Cc6634C0532925a3b844Bc9e7595f0bEb0",
    "TON": "EQDxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx",
    "USDT": "0x742d35Cc6634C0532925a3b844Bc9e7595f0bEb0",
}

CRYPTO_CURRENCIES = {
    "BTC": {"emoji": "₿", "rate": 5000, "min": 0.0005},
    "ETH": {"emoji": "⟠", "rate": 300, "min": 0.01},
    "TON": {"emoji": "💎", "rate": 200, "min": 0.5},
    "USDT": {"emoji": "🪙", "rate": 100, "min": 5},
}

# ===== БАЗА ДАННЫХ =====
class Database:
    def __init__(self):
        self.users = {}
    
    def create_user(self, user_id, username):
        if user_id not in self.users:
            self.users[user_id] = {
                'balance': 100,
                'username': username,
                'stats': {'games': 0, 'wins': 0, 'losses': 0, 'total_won': 0, 'total_bet': 0}
            }
    
    def get_balance(self, user_id):
        return self.users.get(user_id, {}).get('balance', 0)
    
    def add_balance(self, user_id, amount):
        if user_id in self.users:
            self.users[user_id]['balance'] += amount
        else:
            self.users[user_id] = {'balance': amount, 'username': str(user_id)}
    
    def subtract_balance(self, user_id, amount):
        if user_id in self.users:
            self.users[user_id]['balance'] -= amount
    
    def update_stats(self, user_id, bet, win, is_win):
        if user_id not in self.users:
            self.create_user(user_id, str(user_id))
        stats = self.users[user_id].get('stats', {'games': 0, 'wins': 0, 'losses': 0, 'total_won': 0, 'total_bet': 0})
        stats['games'] += 1
        stats['total_bet'] += bet
        if win > 0:
            stats['wins'] += 1
            stats['total_won'] += win
        else:
            stats['losses'] += 1
        self.users[user_id]['stats'] = stats
    
    def get_stats(self, user_id):
        return self.users.get(user_id, {}).get('stats', {'games': 0, 'wins': 0, 'losses': 0, 'total_won': 0, 'total_bet': 0})
    
    def get_leaderboard(self):
        sorted_users = sorted(self.users.items(), key=lambda x: x[1].get('balance', 0), reverse=True)[:10]
        return [(user[1].get('username', str(user[0])), user[1].get('balance', 0), user[1].get('stats', {}).get('wins', 0)) for user in sorted_users]

bot = Bot(token=BOT_TOKEN)
dp = Dispatcher(storage=MemoryStorage())
db = Database()


# ===== FSM STATES =====
class BetStates(StatesGroup):
    waiting_bet = State()
    playing_blackjack = State()
    waiting_crypto_amount = State()
    waiting_crypto_currency = State()


# ===== KEYBOARDS =====
def main_menu_kb():
    kb = InlineKeyboardBuilder()
    kb.button(text="🎰 Слоты", callback_data="game_slots")
    kb.button(text="🎲 Кости", callback_data="game_dice")
    kb.button(text="🃏 Блэкджек", callback_data="game_blackjack")
    kb.button(text="🎡 Рулетка", callback_data="game_roulette")
    kb.button(text="🪙 Монетка", callback_data="game_coin")
    kb.button(text="💣 Мины", callback_data="game_mines")
    kb.adjust(2)
    kb.row(
        InlineKeyboardButton(text="💰 Пополнить", callback_data="deposit"),
        InlineKeyboardButton(text="💸 Вывести", callback_data="withdraw"),
    )
    kb.row(
        InlineKeyboardButton(text="📊 Статистика", callback_data="stats"),
        InlineKeyboardButton(text="🏆 Лидеры", callback_data="leaderboard"),
    )
    kb.row(InlineKeyboardButton(text="ℹ️ Помощь", callback_data="help"))
    return kb.as_markup()


def bet_kb(game: str):
    kb = InlineKeyboardBuilder()
    for amount in [10, 25, 50, 100, 250, 500]:
        kb.button(text=f"⭐ {amount}", callback_data=f"bet_{game}_{amount}")
    kb.adjust(3)
    kb.row(InlineKeyboardButton(text="🔙 Назад", callback_data="back_menu"))
    return kb.as_markup()


def deposit_kb():
    kb = InlineKeyboardBuilder()
    kb.button(text="⭐ 50 Stars = 50 монет", callback_data="stars_50")
    kb.button(text="⭐ 150 Stars = 175 монет", callback_data="stars_150")
    kb.button(text="⭐ 500 Stars = 650 монет", callback_data="stars_500")
    kb.button(text="⭐ 1000 Stars = 1400 монет", callback_data="stars_1000")
    kb.adjust(2)
    kb.row(InlineKeyboardButton(text="₿ Крипта", callback_data="crypto_deposit"))
    kb.row(InlineKeyboardButton(text="🔙 Назад", callback_data="back_menu"))
    return kb.as_markup()


def crypto_kb():
    kb = InlineKeyboardBuilder()
    for coin, data in CRYPTO_CURRENCIES.items():
        kb.button(text=f"{data['emoji']} {coin}", callback_data=f"crypto_{coin}")
    kb.adjust(2)
    kb.row(InlineKeyboardButton(text="🔙 Назад", callback_data="deposit"))
    return kb.as_markup()


def blackjack_kb():
    kb = InlineKeyboardBuilder()
    kb.button(text="✅ Взять карту", callback_data="bj_hit")
    kb.button(text="🛑 Стоп", callback_data="bj_stand")
    kb.button(text="💰 Удвоить", callback_data="bj_double")
    kb.adjust(3)
    return kb.as_markup()


def mines_kb(revealed: list, mines: list, size: int = 5):
    kb = InlineKeyboardBuilder()
    for i in range(size * size):
        if i in revealed:
            if i in mines:
                kb.button(text="💥", callback_data=f"mine_{i}_boom")
            else:
                kb.button(text="💎", callback_data=f"mine_{i}_safe")
        else:
            kb.button(text="⬜", callback_data=f"mine_{i}")
    kb.adjust(size)
    kb.row(
        InlineKeyboardButton(text="💸 Забрать выигрыш", callback_data="mines_cashout"),
        InlineKeyboardButton(text="🔙 Меню", callback_data="back_menu"),
    )
    return kb.as_markup()


# ===== GAME LOGIC =====
class SlotMachine:
    SYMBOLS = ["🍒", "🍋", "🍇", "⭐", "🔔", "💎", "7️⃣", "🃏"]
    WEIGHTS = [30, 25, 20, 12, 8, 3, 1.5, 0.5]
    PAYOUTS = {
        ("🃏", "🃏", "🃏"): 50, ("7️⃣", "7️⃣", "7️⃣"): 30, ("💎", "💎", "💎"): 20,
        ("🔔", "🔔", "🔔"): 10, ("⭐", "⭐", "⭐"): 7, ("🍇", "🍇", "🍇"): 5,
        ("🍋", "🍋", "🍋"): 3, ("🍒", "🍒", "🍒"): 2,
    }
    @classmethod
    def spin(cls):
        result = random.choices(cls.SYMBOLS, weights=cls.WEIGHTS, k=3)
        multiplier = cls.PAYOUTS.get(tuple(result), 0)
        if result.count("🍒") == 2:
            multiplier = max(multiplier, 1.5)
        return result, multiplier


class BlackjackGame:
    CARDS = ['A', '2', '3', '4', '5', '6', '7', '8', '9', '10', 'J', 'Q', 'K']
    CARD_VALUES = {'A': 11, '2': 2, '3': 3, '4': 4, '5': 5, '6': 6, '7': 7,
                   '8': 8, '9': 9, '10': 10, 'J': 10, 'Q': 10, 'K': 10}
    SUITS = ['♠️', '♥️', '♦️', '♣️']
    @classmethod
    def draw_card(cls):
        return random.choice(cls.CARDS), random.choice(cls.SUITS)
    @classmethod
    def hand_value(cls, hand):
        value = sum(cls.CARD_VALUES[c] for c, _ in hand)
        aces = sum(1 for c, _ in hand if c == 'A')
        while value > 21 and aces:
            value -= 10
            aces -= 1
        return value
    @classmethod
    def format_hand(cls, hand, hide_second=False):
        if hide_second and len(hand) > 1:
            return f"{hand[0][0]}{hand[0][1]} 🎴"
        return " ".join(f"{c}{s}" for c, s in hand)
    @classmethod
    def new_game(cls):
        return [cls.draw_card(), cls.draw_card()], [cls.draw_card(), cls.draw_card()]


class RouletteGame:
    RED = {1,3,5,7,9,12,14,16,18,19,21,23,25,27,30,32,34,36}
    BLACK = {2,4,6,8,10,11,13,15,17,20,22,24,26,28,29,31,33,35}
    @classmethod
    def spin(cls):
        return random.randint(0, 36)
    @classmethod
    def get_color_emoji(cls, num):
        if num == 0: return "🟢"
        return "🔴" if num in cls.RED else "⚫"
    @classmethod
    def check_bet(cls, bet_type: str, num: int):
        if bet_type == "green": return num == 0, 14
        elif bet_type == "red": return num in cls.RED, 2
        elif bet_type == "black": return num in cls.BLACK, 2
        elif bet_type == "first": return 1 <= num <= 12, 3
        elif bet_type == "second": return 13 <= num <= 24, 3
        elif bet_type == "third": return 25 <= num <= 36, 3
        return False, 0


MINES_COUNT = 5
MINES_MULTIPLIERS = [1.1, 1.2, 1.35, 1.5, 1.7, 2.0, 2.5, 3.0, 4.0, 5.0,
                     6.5, 8.0, 10.0, 13.0, 17.0, 22.0, 29.0, 38.0, 50.0, 70.0]


# ===== HANDLERS =====
@dp.message(CommandStart())
async def cmd_start(message: types.Message):
    user = message.from_user
    db.create_user(user.id, user.username or user.first_name)
    balance = db.get_balance(user.id)
    if balance == 0:
        db.add_balance(user.id, 100)
        balance = 100
    await message.answer(
        f"🎰 *GOLDEN CROWN CASINO* 🎰\n\nДобро пожаловать, *{user.first_name}*!\n\n💰 Ваш баланс: *{balance} монет*\n\nВыберите игру:",
        reply_markup=main_menu_kb(), parse_mode="Markdown")


@dp.callback_query(F.data == "back_menu")
async def back_to_menu(callback: types.CallbackQuery, state: FSMContext):
    await state.clear()
    await callback.message.edit_text(
        f"🎰 *GOLDEN CROWN CASINO*\n\n💰 Баланс: *{db.get_balance(callback.from_user.id)}* монет\n\nВыберите игру:",
        reply_markup=main_menu_kb(), parse_mode="Markdown")


# ===== SLOTS =====
@dp.callback_query(F.data == "game_slots")
async def game_slots(callback: types.CallbackQuery):
    await callback.message.edit_text(
        f"🎰 *СЛОТЫ*\n\n💰 Баланс: *{db.get_balance(callback.from_user.id)}* монет\n\nВыберите ставку:",
        reply_markup=bet_kb("slots"), parse_mode="Markdown")


@dp.callback_query(F.data.startswith("bet_slots_"))
async def play_slots(callback: types.CallbackQuery):
    bet = int(callback.data.split("_")[2])
    user_id = callback.from_user.id
    if db.get_balance(user_id) < bet:
        await callback.answer("❌ Недостаточно монет!", show_alert=True)
        return
    result, multiplier = SlotMachine.spin()
    win = int(bet * multiplier) if multiplier > 0 else 0
    db.subtract_balance(user_id, bet)
    if win: db.add_balance(user_id, win)
    db.update_stats(user_id, bet, win, win > 0)
    await callback.message.edit_text(
        f"🎰 *СЛОТЫ*\n\n[ {result[0]} | {result[1]} | {result[2]} ]\n\n{'✅ Выигрыш! +'+str(win) if win else '❌ Проигрыш -'+str(bet)} монет\n💰 Баланс: *{db.get_balance(user_id)}* монет",
        reply_markup=bet_kb("slots"), parse_mode="Markdown")


# ===== DICE =====
@dp.callback_query(F.data == "game_dice")
async def game_dice(callback: types.CallbackQuery):
    await callback.message.edit_text(
        f"🎲 *КОСТИ*\n\n💰 Баланс: *{db.get_balance(callback.from_user.id)}* монет\n\nВыберите ставку:",
        reply_markup=bet_kb("dice"), parse_mode="Markdown")


@dp.callback_query(F.data.startswith("bet_dice_"))
async def play_dice_bet(callback: types.CallbackQuery, state: FSMContext):
    bet = int(callback.data.split("_")[2])
    if db.get_balance(callback.from_user.id) < bet:
        await callback.answer("❌ Недостаточно монет!", show_alert=True)
        return
    await state.update_data(dice_bet=bet)
    await callback.message.edit_text(
        f"🎲 Ставка: *{bet}* монет\n\nВаш выбор?",
        reply_markup=InlineKeyboardMarkup(inline_keyboard=[
            [InlineKeyboardButton(text="📈 Больше 7", callback_data="dice_high"),
             InlineKeyboardButton(text="📉 Меньше 7", callback_data="dice_low")]
        ]), parse_mode="Markdown")


@dp.callback_query(F.data.in_({"dice_high", "dice_low"}))
async def resolve_dice(callback: types.CallbackQuery, state: FSMContext):
    data = await state.get_data()
    bet = data.get("dice_bet", 50)
    user_id = callback.from_user.id
    die1, die2 = random.randint(1, 6), random.randint(1, 6)
    total = die1 + die2
    db.subtract_balance(user_id, bet)
    if total == 7:
        win, result_text = bet, "⚖️ Ничья!"
    elif (callback.data == "dice_high" and total > 7) or (callback.data == "dice_low" and total < 7):
        win, result_text = int(bet * 1.9), "✅ Вы угадали!"
    else:
        win, result_text = 0, "❌ Не угадали"
    if win: db.add_balance(user_id, win)
    db.update_stats(user_id, bet, win, win > bet)
    await state.clear()
    await callback.message.edit_text(
        f"🎲 *КОСТИ*\n\n{['','1️⃣','2️⃣','3️⃣','4️⃣','5️⃣','6️⃣'][die1]} + {['','1️⃣','2️⃣','3️⃣','4️⃣','5️⃣','6️⃣'][die2]} = *{total}*\n\n{result_text}\n💰 Баланс: *{db.get_balance(user_id)}* монет",
        reply_markup=InlineKeyboardMarkup(inline_keyboard=[[InlineKeyboardButton(text="🎲 Играть снова", callback_data="game_dice")]]),
        parse_mode="Markdown")


# ===== MAIN =====
async def main():
    logger.info("🎰 Golden Crown Casino Bot starting...")
    await dp.start_polling(bot)

if __name__ == "__main__":
    asyncio.run(main())
