package com.zhibeifw.app.data

import android.icu.text.Transliterator
import com.zhibeifw.app.core.normalizeText

/** 逐字取系统普通话读音，保留课名里的英文字母和数字，略过标点。 */
internal class PinyinSearch {
    private val mandarin = Transliterator.getInstance("Han-Latin; NFD; [:Nonspacing Mark:] Remove; NFC")
    private val syllables = mutableMapOf<Int, String>()

    @Synchronized
    fun matches(cards: List<SeriesCard>, query: String): List<SeriesCard> {
        val byRank = List(4) { mutableListOf<SeriesCard>() }
        for (card in cards) {
            val initials = StringBuilder()
            val full = StringBuilder()
            normalizeText(card.title).codePoints().forEach { cp ->
                val syllable = when {
                    cp in 'a'.code..'z'.code || cp in '0'.code..'9'.code -> cp.toChar().toString()
                    Character.UnicodeScript.of(cp) == Character.UnicodeScript.HAN -> syllables.getOrPut(cp) {
                        mandarin.transliterate(String(Character.toChars(cp))).filter { it in 'a'..'z' }
                    }
                    else -> ""
                }
                syllable.firstOrNull()?.let { initials.append(it); full.append(syllable) }
            }
            val rank = when {
                initials.startsWith(query) -> 0
                query in initials -> 1
                full.startsWith(query) -> 2
                query in full -> 3
                else -> continue
            }
            byRank[rank].add(card)
        }
        return byRank.flatten()
    }
}
