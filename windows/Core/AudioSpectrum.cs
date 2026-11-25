using System.Numerics;

namespace Zhibei;

public sealed class AudioSpectrum
{
    public const int Size = 1024;
    readonly Complex[] bins = new Complex[Size];
    readonly int[] permutation = new int[Size];
    readonly Complex[] roots = new Complex[Size / 2];
    int used;

    public AudioSpectrum()
    {
        for (int i = 1; i < Size; i++) permutation[i] = (permutation[i / 2] >> 1) | ((i & 1) * (Size / 2));
        for (int i = 0; i < roots.Length; i++) roots[i] = Complex.FromPolarCoordinates(1, -2 * Math.PI * i / Size);
    }

    public double[]? Add(double sample, int sampleRate)
    {
        bins[permutation[used++]] = new Complex(sample, 0);
        if (used != Size) return null;
        used = 0;
        for (int length = 2; length <= Size; length *= 2)
        {
            int half = length / 2;
            for (int start = 0; start < Size; start += length)
                for (int j = 0; j < half; j++)
                {
                    int a = start + j, b = a + half;
                    var second = bins[b] * roots[j * (Size / length)];
                    bins[b] = bins[a] - second;
                    bins[a] += second;
                }
        }
        var result = new double[4];
        for (int i = 1; i < Size / 2; i++)
        {
            double hz = (double)i * sampleRate / Size;
            result[hz < 250 ? 0 : hz < 1000 ? 1 : hz < 4000 ? 2 : 3] += bins[i].Real * bins[i].Real + bins[i].Imaginary * bins[i].Imaginary;
        }
        for (int i = 0; i < result.Length; i++) result[i] = Math.Clamp(2 * Math.Sqrt(result[i]) / Size, 0, 1);
        return result;
    }
}
