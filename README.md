# Auction Income

ArcheAge Classic addon by **Ako/Defou1t**.

Counts auction income **only** for the items you pick (for example Weapon / Armor / Accessory Regrade Scroll) and what you spend buying the items you pick (for example Blank Regrade Scroll). The rest of your gold is ignored, so scroll income does not get mixed up with everything else that lands in your wallet.

Считает доход с аукциона **только** по выбранным предметам и расходы на покупку выбранных предметов. Остальные деньги в статистику не попадают. Описание на русском — ниже.

## Features

- **Selling / Buying** lists. Drag an item from your bag onto a slot (Dawnsdrop Check style); right-click a slot to stop tracking it. History stays.
- **Slots**: 1–24 per list, `-` / `+` buttons. `-` only removes an empty last slot; a full list grows by itself.
- **Totals** for today, 7 days, 30 days and the current period:
  - **Received** — money taken from the mail for sold items
  - **In mail** — sold, money not taken yet
  - **Spent** — bought items
  - **Lost fees** — deposits of lots that did not sell
  - **Net** — Received − Spent − Lost fees
- Per item: pieces sold or bought, money, average price per piece.
- Every sale and purchase is saved with date and time; statistics survive game restarts and addon updates.
- **New period** (click twice within 5 s): archives the current statistics and starts counting from zero. Item lists, lots on the auction and money still in the mail carry over. **Archives** lists past periods with their totals.
- **On / Off** per item: Off leaves the item out of all totals but keeps it in the list and keeps recording it; On counts it again.
- **Archives** window: delete one period (X) or all of them (Clear all), both confirmed by a second click.
- **Item IDs / Debug** window: drop an item to see its ID, list the IDs of everything in your bag.
- Manual entry for anything the addon could not see.

## Labor calculator (1.9.0)

The **Labor** button in the main window opens a calculator that answers "what is one labor point worth in each activity, and is it cheaper to make or to buy?".

- **Records itself.** Tracking is on all game long; every labor spend goes into the current record and a new record starts when the activity changes. An activity is **vocation + loot type**: `Logging (bundle)` (stumps), `Alchemy` (geode harvest), `Alchemy (craft)` (shards into points), `Mining (loot)`, `Fishing` (worm fishing has no vocation, it is recognised by its catch).
- A record holds labor, play time, items received within 8 s of a spend (+) and items used for it (−: craft materials, bait). Mob loot, quest rewards and vendor purchases are left out. Gold that drops together with the labor (opening purses, Larceny) is added to the record.
- Stumps lit under a geode wait for the next geode harvest, mineral water poured on an archeum tree for the next tree harvest, and count as its cost. A pack carried on the back is neither used nor gained.
- **Trade pack payments** that arrive by mail hours later — gold (taking it costs 1 Commerce labor), Charcoal Stabilizer, Dragon Essence Stabilizer — are added to the latest pack (Commerce) record without interrupting the current activity.
- Items used up without labor (points spent elsewhere, festival coins) are nobody's cost. Labor with neither vocation nor loot (sport fishing, −18) gets its own record, `Labor (18 LP)`.
- Time: the walk to the next activity belongs to it; after 10 minutes without labor the clock stops (AFK).
- **Every field is editable**: name, LP, gold +/- (e.g. a trade pack paid 6–8 hours later) and, per item, count (0 removes the row) and price of one piece — `0.04`, `0,04`, `4s`, `1g 20s`, `-47`. One **Save** applies them. Saved records open with **Edit**.
- **Prices**: your own (set) → market → average of your own auction deals. **Market prices** come from [sermeatball.com](https://sermeatball.com) (7-day auction averages; the regrade panel uses the latest price): double-click `update-prices.cmd` in the addon folder, then press **Market** in the window. Addons cannot go online, so the download runs outside the game.
- **Views**: best gold per LP, newest, **by activity** (all records of one activity summed; **Items** shows how many of each item one action and 100 LP bring — shards and points per geode).
- **Don't track** switches off junk activities (one or two random actions) for good; **Track again** undoes it.
- **Split: auto / manual** — in manual one record runs until **New record**. **Tracking ON/OFF** pauses, **Discard** drops the running record.

## Fish Tracker (1.10.0)

Moved here from Raid & Fish Tools (now Raid Tools 1.4.0); based on Fish Track Reborn v2.2 by **Wagasez**, inspired by Usb, via Norrina-Hub by **Norrina**. **Fish: On/Off** in the main window.

- Target a fish (Marlin, Tuna, Sailfish, Sturgeon, Sunfish, Carp, Eel, Arowana, …): its action with a timer and Strength Contest show under it. A second panel (**W**) follows the watch / track target.
- Fish marked 1–9 get a 150 s countdown after death; your boat's Owner's Mark gets one too.
- Light on the 32-bit client: only the position of a shown panel is updated every frame (and re-anchored only when it moved a pixel), buffs and timers 10 times a second, markers twice a second, unit info only when the target changes; every widget is touched only when its text, icon or visibility changes. **Off** does nothing at all. An error inside the tracker switches only the tracker off until the next start.

## Regrade panel (1.11.0)

**Regrade: On/Off** in the main window. Open the Enchant window on its regrade tab and a panel appears beside it (inspired by the attempt log of [regrades.thebouncycow.com](https://regrades.thebouncycow.com/)):

- Auction prices of what is in the slots — the item, the scroll and the charm — plus gold per try, **item + scroll + charm**, and **one try** (scroll + charm + gold).
- Prices: your own (set) → latest auction price → 7-day average, both from [sermeatball.com](https://sermeatball.com) (`update-prices.cmd`). Gear has one market price for all grades, so type your own into the box and press **Save prices**; an emptied box goes back to the market price. Your own prices are shared with the labor calculator.
- A table of the tries made while the window is open: number, grade before → after, result (Success, Great success, Fail, Downgrade, Break) and the cost of the try, with counts and the total spent on top. It is cleared when the window closes.
- The slots are read 4 times a second while the window is open, nothing while it is closed; results come from the client's `GRADE_ENCHANT_RESULT` event.

## How it detects things

| What | How |
|---|---|
| Listing | the deposit leaves the wallet and the item leaves the bag as an auction listing — item, count and deposit (1% of the price) are remembered |
| Sale | the client's auction-sold event (item and price); the count comes from the lot |
| Sale money | money taken from mail is matched to the pending sale (price − auction fee + deposit refund) |
| Unsold lot | the item comes back by mail — its deposit goes to Lost fees |
| Auction purchase | money leaves the wallet and a new mail arrives; when the tracked item is taken from that mail it gets this cost |
| Vendor purchase | money leaves the wallet and the tracked item appears in the bag at the same moment |

## Limits

- Sales that happen while you are offline are not seen (addons cannot read mail contents) — add them manually.
- Stack size is known only for lots listed while the addon was running; older lots are recorded as x1 (the money is still right).
- After updating from a version below 1.5.0, restart the game once (older versions left a copy running after a reload from the Addons window).

## Data and updating

`Documents\AAClassic\Addon\auction_income_data.lua` — outside the addon folder, so updates never touch it. Auction records are written at once; the labor calculator writes at most every 15 s (1.10.0; 1.9.2: up to 1.9.1 every event rewrote the whole file and every save re-read it to check for a second running copy, churning memory of the 32-bit client). 1.10.0 also stops building a date every frame and formatting event arguments when the debug log is off. Delete it with the game closed to start over.

**Update:** double-click `update-addons.cmd` in the addon folder. It backs up the addon folders and data files to `Addon\_backups\<date>`, then installs the latest GitHub releases of Auction Income and Raid Tools (only the ones you have; Auction Income is added where Raid & Fish Tools is installed, since it now holds the Fish Tracker). Unzipping a release over the folder works too.

Обновление: дважды кликните `update-addons.cmd` в папке аддона — сначала копия в `Addon\_backups\<дата>`, потом последние версии Auction Income и Raid & Fish Tools (только установленные). Записи лежат вне папки аддона и не затираются.

---

## По-русски

- **Selling / Buying** — два списка: что продаёте и что покупаете. Перетащите предмет из сумки на ячейку; правый клик — убрать (история остаётся).
- **Slots** — от 1 до 24 ячеек, кнопки `-` / `+`. `-` убирает только пустую последнюю ячейку.
- **Итоги** за сегодня, 7 дней, 30 дней и всё время: Received (получено из почты), In mail (продано, не забрано), Spent (покупки), Lost fees (залоги непроданных лотов), Net.
- Каждая продажа и покупка сохраняется с датой и временем; статистика переживает перезапуск игры и обновление аддона.
- **New period** (два нажатия за 5 секунд) — закрыть текущую статистику в архив и начать заново; **Archives** — прошлые периоды с итогами.
- **Item IDs / Debug** — ID предмета и всего содержимого сумки.

**Калькулятор очков работы** (кнопка **Labor**, версия 1.9.0):

- Пишет всю игру сам и делит на записи по занятию = профессия + вид добычи: `Logging (bundle)` (пеньки), `Alchemy` (жеоды), `Alchemy (craft)` (шарды в поинты), `Fishing` и т. д. Сменили занятие — новая запись.
- В записи: ОР, время, полученные предметы (+), израсходованные (−: материалы, черви), золото с кошельков (Larceny). Лут с мобов и награды заданий не считаются. Подожжённые пеньки входят в затраты следующего сбора жеод, вылитая на дерево вода — сбора акхиумных деревьев.
- Оплата паков по почте (золото, Charcoal / Dragon Essence Stabilizer) сама дописывается в последнюю запись с паками.
- Все поля правятся: имя, ОР, Gold +/- (например оплата паков), количество и цена штуки (`4s`, `0.04`, `1g 20s`) — и одна кнопка **Save**.
- Цены: своя → рынок с sermeatball.com (`update-prices.cmd` в папке аддона, затем кнопка **Market**) → средняя ваших сделок.
- **View**: лучшие за 1 ОР / новые / по занятиям; **Items** — сколько предметов в среднем за действие и за 100 ОР.
- **Don't track** — отключить мусорное занятие, **Track again** — вернуть.

**Fish Tracker** (1.10.0, переехал из Raid & Fish Tools; кнопка **Fish: On/Off**): возьмите рыбу в цель — под ней действие рыбы с таймером и Strength Contest, панель **W** — под наблюдаемой целью; таймеры 150 с у мёртвых рыб с номером и Owner's Mark лодки. Каждый кадр двигается только позиция панели, баффы — 10 раз в секунду; **Off** не делает ничего.

**Панель регрейда** (1.11.0; кнопка **Regrade: On/Off**): рядом с окном улучшения — цены предмета, свитка и талисмана из слотов, золото за попытку, их сумма и цена одной попытки. Цены: своя → последняя на аукционе → средняя за 7 дней (sermeatball.com). У снаряжения одна рыночная цена на все грейды — впишите свою и нажмите **Save prices**. Таблица попыток (грейд было → стало, результат, цена) живёт, пока окно открыто.

Аддон запоминает лот при выставлении (предмет, количество, залог), ловит событие продажи, сопоставляет деньги из почты с продажей, а вернувшийся непроданный лот записывает как потерянный залог. Покупка на аукционе — списание денег и новое письмо; сумма привязывается к предмету, когда вы забираете его из почты.

Ограничения: продажи, пока вас нет в игре, не видны (добавьте вручную); после обновления с версии ниже 1.5.0 один раз перезапустите игру.

Данные: `Документы\AAClassic\Addon\auction_income_data.lua`.
