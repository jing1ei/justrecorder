namespace JustRecorder.Core;
/// Interleaved stereo samples. All operations are owned by the capture lock.
public sealed class FloatRing(int capacity)
{
    readonly float[] data = new float[Math.Max(2, capacity / 2 * 2)]; int next, count;
    public void Append(ReadOnlySpan<float> samples)
    {
        if (samples.Length % 2 != 0) throw new ArgumentException("Stereo samples must be frame aligned.");
        if (samples.Length >= data.Length)
        {
            samples[^data.Length..].CopyTo(data);
            next = 0;
            count = data.Length;
            return;
        }
        var head = Math.Min(samples.Length, data.Length - next);
        samples[..head].CopyTo(data.AsSpan(next));
        samples[head..].CopyTo(data);
        next = (next + samples.Length) % data.Length;
        count = Math.Min(count + samples.Length, data.Length);
    }
    public float[] Drain()
    {
        var result = new float[count]; var start = (next - count + data.Length) % data.Length;
        var head = Math.Min(count, data.Length - start); Array.Copy(data, start, result, 0, head); Array.Copy(data, 0, result, head, count - head);
        count = 0; next = 0; return result;
    }
}
