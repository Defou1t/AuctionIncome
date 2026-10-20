# Auction Income

ArcheAge Classic addon by **Ako/Defou1t**.

Counts auction income **only** for the items you pick (for example Weapon / Armor / Accessory Regrade Scroll) and what you spend buying the items you pick (for example Blank Regrade Scroll). The rest of your gold is ignored, so scroll income does not get mixed up with everything else that lands in your wallet.

Считает доход с аукциона **только** по выбранным предметам и расходы на покупку выбранных предметов. Остальные деньги в статистику не попадают. Описание на русском — ниже.

## Features

- **Selling / Buying** lists. Drag an item from your bag onto a slot (Dawnsdrop Check style); right-click a slot to stop tracking it. History stays.
- **Slots**: 1–24 per list, `-` / `+` buttons. `-` only removes an empty last slot; a full list grows by itself.
- **Totals** for today, 7 days, 30 days and all time:
  - **Received** — money taken from the mail for sold items
  - **In mail** — sold, money not taken yet
  - **Spent** — bought items
  - **Lost fees** — deposits of lots that did not sell
  - **Net** — Received − Spent − Lost fees
- Per item: pieces sold or bought, money, average price per piece.
- Every sale and purchase is saved with date and time; statistics survive game restarts and addon updates.
- **Item IDs / Debug** window: drop an item to see its ID, list the IDs of everything in your bag.
- Manual entry for anything the addon could not see.

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

## Data

`Documents\AAClassic\Addon\auction_income_data.lua`, saved on every change. Delete it with the game closed to start over.

---

## По-русски

- **Selling / Buying** — два списка: что продаёте и что покупаете. Перетащите предмет из сумки на ячейку; правый клик — убрать (история остаётся).
- **Slots** — от 1 до 24 ячеек, кнопки `-` / `+`. `-` убирает только пустую последнюю ячейку.
- **Итоги** за сегодня, 7 дней, 30 дней и всё время: Received (получено из почты), In mail (продано, не забрано), Spent (покупки), Lost fees (залоги непроданных лотов), Net.
- Каждая продажа и покупка сохраняется с датой и временем; статистика переживает перезапуск игры и обновление аддона.
- **Item IDs / Debug** — ID предмета и всего содержимого сумки.

Аддон запоминает лот при выставлении (предмет, количество, залог), ловит событие продажи, сопоставляет деньги из почты с продажей, а вернувшийся непроданный лот записывает как потерянный залог. Покупка на аукционе — списание денег и новое письмо; сумма привязывается к предмету, когда вы забираете его из почты.

Ограничения: продажи, пока вас нет в игре, не видны (добавьте вручную); после обновления с версии ниже 1.5.0 один раз перезапустите игру.

Данные: `Документы\AAClassic\Addon\auction_income_data.lua`.
