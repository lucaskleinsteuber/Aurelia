using System.Net;
using Aurelia.Contracts;
using Xunit;

namespace Aurelia.Server.Tests;

public sealed class ServerFolderTests
{
    [Fact]
    public async Task OwnersBrowseServerFoldersButNeverFilesLinksOrHiddenFolders()
    {
        var root = Directory.CreateTempSubdirectory("aurelia-folders-");
        try
        {
            Directory.CreateDirectory(Path.Combine(root.FullName, "Shows"));
            Directory.CreateDirectory(Path.Combine(root.FullName, "Movies"));
            Directory.CreateDirectory(Path.Combine(root.FullName, ".Hidden"));
            Directory.CreateDirectory(Path.Combine(root.FullName, "Outside"));
            Directory.CreateSymbolicLink(Path.Combine(root.FullName, "Linked"), Path.Combine(root.FullName, "Outside"));
            File.WriteAllBytes(Path.Combine(root.FullName, "Synthetic.mkv"), [1, 2, 3]);

            using var factory = new AureliaServerFactory();
            using var client = factory.CreateClient();
            var owner = await ApiTestClient.SetupOwnerAsync(client);

            var places = await ListAsync(client, owner.Token, null);
            Assert.Null(places.Path);
            Assert.NotEmpty(places.Folders);

            var listing = await ListAsync(client, owner.Token, root.FullName);
            Assert.Equal(Path.GetFullPath(root.FullName), listing.Path);
            Assert.Equal(root.Parent!.FullName, listing.Parent);
            Assert.Equal(["Movies", "Outside", "Shows"], listing.Folders.Select(folder => folder.Name));
            Assert.Equal(Path.Combine(root.FullName, "Movies"), listing.Folders[0].Path);

            using (var relative = ApiTestClient.Authorized(HttpMethod.Get, "/api/v1/libraries/folders?path=Movies", owner.Token))
            using (var response = await client.SendAsync(relative))
            {
                Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);
            }

            var missing = Uri.EscapeDataString(Path.Combine(root.FullName, "Missing"));
            using (var request = ApiTestClient.Authorized(HttpMethod.Get, $"/api/v1/libraries/folders?path={missing}", owner.Token))
            using (var response = await client.SendAsync(request))
            {
                Assert.Equal(HttpStatusCode.NotFound, response.StatusCode);
            }

            using (var anonymous = await client.GetAsync("/api/v1/libraries/folders"))
            {
                Assert.Equal(HttpStatusCode.Unauthorized, anonymous.StatusCode);
            }
        }
        finally
        {
            root.Delete(recursive: true);
        }
    }

    private static async Task<ServerFolderListing> ListAsync(HttpClient client, string token, string? path)
    {
        var query = path is null ? "" : "?path=" + Uri.EscapeDataString(path);
        using var request = ApiTestClient.Authorized(HttpMethod.Get, "/api/v1/libraries/folders" + query, token);
        using var response = await client.SendAsync(request);
        response.EnsureSuccessStatusCode();
        return await ApiTestClient.ReadAsync<ServerFolderListing>(response);
    }
}
