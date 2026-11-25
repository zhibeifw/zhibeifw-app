using System.Runtime.InteropServices;
using System.Text;

namespace Zhibei;

// Windows 11 自带的 ICU。逐字转换，与其他端的首字母和全拼匹配一致。
internal static class Pinyin
{
    [DllImport("icu", CharSet = CharSet.Unicode, ExactSpelling = true)]
    static extern IntPtr utrans_openU(string id, int length, int direction, IntPtr rules, int rulesLength, IntPtr parseError, ref int status);
    [DllImport("icu", ExactSpelling = true)]
    static extern void utrans_transUChars(IntPtr transform, [In, Out] ushort[] text, ref int length, int capacity, int start, ref int limit, ref int status);
    [DllImport("icu", ExactSpelling = true)]
    static extern void utrans_close(IntPtr transform);

    internal static Dictionary<Course, (string, string)> Index(List<Course> courses)
    {
        const string transform = "Han-Latin; NFD; [:Nonspacing Mark:] Remove; NFC; Lower";
        int status = 0;
        var handle = utrans_openU(transform, transform.Length, 0, IntPtr.Zero, 0, IntPtr.Zero, ref status);
        Dictionary<Course, (string, string)> keys = [];
        Dictionary<Rune, string> syllables = [];
        try
        {
            foreach (var course in courses)
            {
                var initials = new StringBuilder();
                var full = new StringBuilder();
                foreach (var rune in Catalog.Normalize(course.Title).EnumerateRunes())
                {
                    if (!syllables.TryGetValue(rune, out var syllable))
                    {
                        syllable = Convert(rune, handle);
                        syllables.Add(rune, syllable);
                    }
                    if (syllable.Length == 0) continue;
                    initials.Append(syllable[0]);
                    full.Append(syllable);
                }
                keys.Add(course, (initials.ToString(), full.ToString()));
            }
        }
        finally { if (handle != IntPtr.Zero) utrans_close(handle); }
        return keys;
    }

    static string Convert(Rune rune, IntPtr handle)
    {
        if (rune.IsAscii) return char.IsAsciiLetterOrDigit((char)rune.Value) ? rune.ToString() : "";
        if (handle == IntPtr.Zero) return "";
        var chars = new ushort[64];
        var input = rune.ToString();
        for (int i = 0; i < input.Length; i++) chars[i] = input[i];
        int length = input.Length, limit = length, status = 0;
        utrans_transUChars(handle, chars, ref length, chars.Length, 0, ref limit, ref status);
        return status <= 0 ? new string(chars.Take(length).Select(c => (char)c).Where(char.IsAsciiLetter).ToArray()) : "";
    }
}
