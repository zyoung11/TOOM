package toom

// lang_zh selects the Chinese interface text. English is the default
// and the choice persists in the config file.
lang_zh: bool

// tr picks the Chinese or English variant of one interface text.
tr :: proc(en, zh: string) -> string {
	if lang_zh {
		return zh
	}
	return en
}
