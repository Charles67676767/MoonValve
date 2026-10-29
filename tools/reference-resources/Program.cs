using System.Text;
using System.Text.Json;
using ValveKeyValue;
using ValveResourceFormat;
using ValveResourceFormat.ResourceTypes;

// Independent test adapter. No reference implementation runs in product code.
Console.InputEncoding = new UTF8Encoding(false);
Console.OutputEncoding = new UTF8Encoding(false);
string? line;
while ((line = Console.ReadLine()) != null)
{
    try
    {
        using var json = JsonDocument.Parse(line);
        var request = json.RootElement;
        var block = new BinaryKV3(BlockType.Undefined) { Resource = null! };
        if (request.TryGetProperty("resource", out var resourceData))
        {
            using var resource = new Resource();
            var bytes = Convert.FromBase64String(resourceData.GetString()!);
            resource.Read(new MemoryStream(bytes));
            var data = resource.DataBlock!;
            block.Size = data.Size;
            using var dataStream = new MemoryStream(bytes.AsSpan((int)data.Offset, (int)data.Size).ToArray());
            using var dataReader = new BinaryReader(dataStream);
            block.Read(dataReader);
        }
        else if (request.TryGetProperty("binary", out var binary))
        {
            var bytes = Convert.FromBase64String(binary.GetString()!);
            block.Size = (uint)bytes.Length;
            using var stream = new MemoryStream(bytes);
            using var reader = new BinaryReader(stream);
            block.Read(reader);
        }
        else
        {
            var serializer = KVSerializer.Create(KVSerializationFormat.KeyValues3Text);
            using var stream = new MemoryStream(Encoding.UTF8.GetBytes(request.GetProperty("text").GetString()!));
            var document = serializer.Deserialize(stream);
            block = new BinaryKV3(document.Root, document.Header!.Format, BlockType.Undefined) { Resource = null! };
        }
        block.SerializationVersion = request.TryGetProperty("version", out var version) ? version.GetInt32() : 5;
        block.SerializationCompressionMethod = (KV3BinaryCompressionMethod)(request.TryGetProperty("compression", out var compression) ? compression.GetInt32() : 0);
        using var output = new MemoryStream();
        block.Serialize(output);
        Console.WriteLine(JsonSerializer.Serialize(new { ok = true, text = block.ToString(), binary = Convert.ToBase64String(output.ToArray()) }));
    }
    catch (Exception error)
    {
        Console.WriteLine(JsonSerializer.Serialize(new { ok = false, error = error.GetType().Name + ": " + error.Message }));
    }
}
