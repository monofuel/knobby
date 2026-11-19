import
  std/[json, tables],
  ./[discord_menu, work_menu]

type
  TaskMenuLink* = object
    menu*, target*, title*, art*: string
    key*: int

const
  SoftmaxDiscordKey* = 13
  DiscordSoftmaxKey* = 8
  PrefixSoftmaxDiscordKey* = 3
  PrefixDiscordSoftmaxKey* = 4
  DiscordLinkTitle* = "Discord menu"
  SoftmaxLinkTitle* = "Softmax"
  DiscordLinkArt* = "discord/menu-discord"
  SoftmaxLinkArt* = "work/menu-work"
  TaskMenuLinks* = [
    TaskMenuLink(menu: WorkMenuId, key: SoftmaxDiscordKey, target: DiscordMenuId,
      title: DiscordLinkTitle, art: DiscordLinkArt),
    TaskMenuLink(menu: DiscordMenuId, key: DiscordSoftmaxKey, target: WorkMenuId,
      title: SoftmaxLinkTitle, art: SoftmaxLinkArt)]

proc linkAction(link: TaskMenuLink): JsonNode =
  ## Return the Deck-only menu action a reciprocal task link performs.
  %*{"kind": "menu", "menu": link.target, "target": "deck"}

proc findMenu(config: JsonNode, id: string): JsonNode =
  ## Return a configured menu by id, refusing to proceed when it is missing.
  for menu in config["menus"]:
    if menu["id"].getStr() == id: result = menu
  if result.isNil:
    raise newException(ValueError, "The " & id & " menu is missing; install it before linking task menus.")

proc linkSlot(menu: JsonNode, link: TaskMenuLink): int =
  ## Return the Deck entry index for a link's key, or -1, refusing a foreign action there.
  result = -1
  for index in 0..<menu["deck"].len:
    if menu["deck"][index]["key"].getInt() == link.key: result = index
  if result >= 0:
    let action = menu["deck"][result]{"action"}
    if not action.isNil and action{"kind"}.getStr() != "none" and action != linkAction(link):
      raise newException(ValueError, "The " & link.menu & " menu Deck key " & $link.key &
        " already has a different action; refusing to replace it.")

proc prefixLinks(): array[2, TaskMenuLink] =
  ## Return the task links at their shared navigation-prefix keys.
  result = TaskMenuLinks
  result[0].key = PrefixSoftmaxDiscordKey
  result[1].key = PrefixDiscordSoftmaxKey

proc hasLink(config: JsonNode, link: TaskMenuLink): bool =
  ## Check whether a link's menu already runs its exact action on its key.
  for entry in findMenu(config, link.menu)["deck"]:
    if entry["key"].getInt() == link.key and entry{"action"} == linkAction(link): result = true

proc activeTaskMenuLinks*(config: JsonNode): array[2, TaskMenuLink] =
  ## Return the shared-prefix link keys when both menus already use them, otherwise the legacy keys.
  result = prefixLinks()
  for link in result:
    if not config.hasLink(link): result = TaskMenuLinks

proc installTaskMenuLinks*(source: JsonNode, artwork: Table[string, string]): JsonNode =
  ## Return an owned configuration with reciprocal Deck keys between the Softmax and Discord menus.
  ## Links already at the shared navigation prefix are kept there; otherwise the legacy keys are used.
  ## Free keys receive new links; existing matching links keep their titles and only refresh
  ## their image. Any other action on either key is refused before anything changes.
  result = parseJson($source)
  let links = activeTaskMenuLinks(result)
  var slots: seq[int]
  for link in links:
    slots.add(linkSlot(findMenu(result, link.menu), link))
  for index, link in links:
    let
      menu = findMenu(result, link.menu)
      image = artwork[link.art]
      slot = slots[index]
    if slot >= 0 and menu["deck"][slot]{"action"} == linkAction(link):
      let entry = menu["deck"][slot]
      if not entry.hasKey("visual"): entry["visual"] = %*{"showTitle": false}
      entry["visual"]["image"] = %image
    else:
      let entry = %*{"key": link.key, "title": link.title, "action": linkAction(link),
        "visual": {"image": image, "showTitle": false}}
      if slot >= 0: menu["deck"].elems[slot] = entry
      else: menu["deck"].add(entry)
