Tailor
===========

Retail WoW addon for Midnight 12.1.x.

Behavior:
- Scans the player's equipped bags on PLAYER_LOGIN.
- Re-scans after BAG_UPDATE_DELAYED.
- Scores armor and weapons with adjustable 0.00-1.00 weights for Armor, Weapon DPS,
  Stamina, Strength, Intellect, Agility, Critical Strike, Haste, Spirit, MP5,
  Spell Damage, and Spell Healing.
- Armor and Weapon DPS default to 1.00; other weights default to 0.00.
- Stat weights are saved per character and restored before the options sliders
  are initialized on login or /reload.
- All equippable character slots except Shirt and Tabard are considered,
  including neck, rings, trinkets, and held off-hand items. Empty slots
  accept an item even when its weighted value is zero.
- Weapon recommendations compare complete main-hand/off-hand combinations.
  Off-hand weapons require Dual Wield. Shield combinations and eligible
  two-handed weapons are compared against the combined currently equipped
  weighted value.
- Weapon, shield, and held off-hand candidates must pass the current
  character's equip requirements, including weapon type proficiency.
- Cloth, leather, mail, and plate candidates must be within the character's
  class armor proficiency. Lower armor tiers remain eligible. Cloaks and
  shields are handled separately from this armor type check.
- Equipment candidates are filtered with C_Item.IsEquippableItem; weapon
  candidates also pass C_PlayerInfo.CanUseItem.
- The scan waits for item information to load, then selects the strongest upgrade for each equipment slot.
- Upgrade prompts wait until combat ends. A prompt interrupted by combat
  returns to the queue, and Tailor rescans before showing another prompt.
- Quest completion rewards that improve the character's weighted equipment
  score receive a green outline, including item choices and fixed item rewards.
  Ring, trinket, and weapon rewards use the same paired-slot comparisons as bags.
- A scrollable two-column upgrade dialog shows both items' weighted values
  and all relevant item stats. Equipped and upgrade values are white; only
  nonzero differences beside upgrade values are colored green or red. Item
  names use quality colors. The dialog can be dragged and sizes to its content.
- /tailor scans manually.
- /tailor options opens the weight sliders in the AddOns settings.
- The upgrade prompt has an Options button.
- /tailor reset clears the current-session prompt suppression.

Install:
1. Extract the Tailor folder into:
   World of Warcraft/_retail_/Interface/AddOns/
2. Restart WoW or type /reload.

Current live Retail interface:
12.1.0 / interface 120100.
