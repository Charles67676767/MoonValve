using System.Globalization;
using System.Text;
using System.Text.Json;
using ValveKeyValue;

// JSON-lines adapter only; all reference parsing is performed by ValveKeyValue.
Console.InputEncoding = new UTF8Encoding(false);
Console.OutputEncoding = new UTF8Encoding(false);
string? line;
while ((line = Console.ReadLine()) != null)
{
    try
    {
        using var json = JsonDocument.Parse(line);
        var request = json.RootElement;
        var binary = request.TryGetProperty("binary", out var binaryInput);
        var kv3 = request.TryGetProperty("kv3", out var kv3Mode) && kv3Mode.GetBoolean();
        var options = new KVSerializerOptions { HasEscapeSequences = true };
        options.Conditions.Clear();
        if (request.TryGetProperty("symbols", out var symbols))
            foreach (var value in symbols.EnumerateArray()) options.Conditions.Add(value.GetString()!);
        if (request.TryGetProperty("files", out var files)) options.FileLoader = new VirtualFiles(files);
        using var input = new MemoryStream(binary ? Convert.FromBase64String(binaryInput.GetString()!) : Encoding.UTF8.GetBytes(request.GetProperty("text").GetString()!));
        var serializer = KVSerializer.Create(kv3 ? KVSerializationFormat.KeyValues3Text : binary ? KVSerializationFormat.KeyValues1Binary : KVSerializationFormat.KeyValues1Text);
        var document = serializer.Deserialize(input, options);
        object Pack(KVObject value) => value.IsCollection
            ? value.Children.Select(p => new { key = p.Key, value = Pack(p.Value) }).ToArray()
            : value.ToString(CultureInfo.InvariantCulture);
        var tree = kv3 ? Array.Empty<object>() : document.Name is null ? Pack(document.Root) : new[] { new { key = document.Name, value = Pack(document.Root) } };
        using var output = new MemoryStream();
        serializer.Serialize(output, document, options);
        Console.WriteLine(JsonSerializer.Serialize(new { ok = true, tree, roundtrip = Convert.ToBase64String(output.ToArray()) }));
    }
    catch (Exception error)
    {
        Console.WriteLine(JsonSerializer.Serialize(new { ok = false, error = error.GetType().Name + ": " + error.Message }));
    }
}

sealed class VirtualFiles(JsonElement files) : IIncludedFileLoader
{
    public Stream OpenFile(string path) => new MemoryStream(Encoding.UTF8.GetBytes(files.GetProperty(path).GetString()!));
}
