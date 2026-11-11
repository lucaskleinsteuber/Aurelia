using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using Aurelia.Contracts;
using Aurelia.Server.Data;
using Aurelia.Server.Services;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;
using Xunit;

namespace Aurelia.Server.Tests;

/// <summary>The browser app: its files, its code sign-in and its HttpOnly cookie credentials.</summary>
public sealed class WebAppTests
{
    [Fact]
    public void EmbeddedAssetsLoadOnlyOnDemandAndConcurrentReadersShareOneValue()
    {
        var assets = new Aurelia.Server.Services.WebAppAssets();
        var field = typeof(Aurelia.Server.Services.WebAppAssets).GetField("assets", System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Instance)!;
        var cache = Assert.IsType<Dictionary<string, Lazy<Aurelia.Server.Services.WebAppAssets.Asset>>>(field.GetValue(assets));
        Assert.All(cache.Values, value => Assert.False(value.IsValueCreated));
        var results = new Aurelia.Server.Services.WebAppAssets.Asset?[32];
        Parallel.For(0, results.Length, index => results[index] = assets.Find("js/app.js"));
        var first = Assert.IsType<Aurelia.Server.Services.WebAppAssets.Asset>(results[0]);
        Assert.All(results, result => Assert.Same(first, result));
        Assert.Equal("text/javascript; charset=utf-8", first.ContentType);
        Assert.Single(cache.Values, value => value.IsValueCreated);
        Assert.Null(assets.Find("missing.js"));
        Assert.All(cache.Where(value => value.Key.StartsWith("icons/", StringComparison.Ordinal)), value => Assert.False(value.Value.IsValueCreated));
        Assert.NotNull(assets.Find("index.html"));
        Assert.Equal(2, cache.Values.Count(value => value.IsValueCreated));
    }

    [Fact]
    public async Task PageLoadsItsFilesFromAVersionedFolderTheBrowserKeepsForGood()
    {
        using var factory = new AureliaServerFactory();
        using var client = factory.CreateClient();
        using var page = await client.GetAsync("/");
        var html = await page.Content.ReadAsStringAsync();
        var match = System.Text.RegularExpressions.Regex.Match(html, "src=\"/web/v/([0-9a-f]{16})/js/app\\.js\"");
        Assert.True(match.Success, html);
        var version = match.Groups[1].Value;
        Assert.Contains($"href=\"/web/v/{version}/app.css\"", html, StringComparison.Ordinal);
        // Every module is announced, so the browser fetches them side by side.
        foreach (var module in new[] { "api.js", "logic.js", "player.js", "settings.js", "dom.js" })
            Assert.Contains($"<link rel=\"modulepreload\" href=\"/web/v/{version}/js/{module}\">", html, StringComparison.Ordinal);
        Assert.True(page.Headers.CacheControl?.NoCache);
        Assert.DoesNotContain("unsafe", Assert.Single(page.Headers.GetValues("Content-Security-Policy")), StringComparison.Ordinal);

        using (var script = await client.GetAsync($"/web/v/{version}/js/app.js"))
        {
            Assert.Equal(HttpStatusCode.OK, script.StatusCode);
            Assert.True(script.Headers.CacheControl?.Public);
            Assert.Equal(TimeSpan.FromDays(365), script.Headers.CacheControl?.MaxAge);
            Assert.Contains("immutable", script.Headers.CacheControl!.ToString(), StringComparison.Ordinal);
            var plain = await (await client.GetAsync("/web/js/app.js")).Content.ReadAsByteArrayAsync();
            Assert.Equal(plain, await script.Content.ReadAsByteArrayAsync());
        }
        using (var stale = await client.GetAsync("/web/v/0000000000000000/js/app.js"))
            Assert.Equal(HttpStatusCode.NotFound, stale.StatusCode);
        using (var index = await client.GetAsync($"/web/v/{version}/index.html"))
            Assert.Equal(HttpStatusCode.NotFound, index.StatusCode);
    }

    [Theory]
    [InlineData("br, gzip", "br")]
    [InlineData("gzip", "gzip")]
    [InlineData("gzip, br;q=0", "gzip")]
    [InlineData("identity", null)]
    public async Task TextFilesComeCompressedWhenTheBrowserAcceptsIt(string accepted, string? expected)
    {
        using var factory = new AureliaServerFactory();
        using var client = factory.CreateClient();
        using var plainResponse = await client.GetAsync("/web/js/app.js");
        var plain = await plainResponse.Content.ReadAsByteArrayAsync();
        using var request = new HttpRequestMessage(HttpMethod.Get, "/web/js/app.js");
        request.Headers.TryAddWithoutValidation("Accept-Encoding", accepted);
        using var response = await client.SendAsync(request);
        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        Assert.Contains("Accept-Encoding", response.Headers.Vary);
        var body = await response.Content.ReadAsByteArrayAsync();
        if (expected is null)
        {
            Assert.Empty(response.Content.Headers.ContentEncoding);
            Assert.Equal(plain, body);
            return;
        }
        Assert.Equal(expected, Assert.Single(response.Content.Headers.ContentEncoding));
        Assert.True(body.Length < plain.Length / 2);
        using var input = new MemoryStream(body);
        using Stream decoder = expected == "br"
            ? new System.IO.Compression.BrotliStream(input, System.IO.Compression.CompressionMode.Decompress)
            : new System.IO.Compression.GZipStream(input, System.IO.Compression.CompressionMode.Decompress);
        using var output = new MemoryStream();
        await decoder.CopyToAsync(output);
        Assert.Equal(plain, output.ToArray());
        // The compressed form has its own tag and answers "unchanged" to it.
        using var again = new HttpRequestMessage(HttpMethod.Get, "/web/js/app.js");
        again.Headers.TryAddWithoutValidation("Accept-Encoding", accepted);
        again.Headers.IfNoneMatch.Add(response.Headers.ETag!);
        using var unchanged = await client.SendAsync(again);
        Assert.Equal(HttpStatusCode.NotModified, unchanged.StatusCode);
        Assert.NotEqual(plainResponse.Headers.ETag!.Tag, response.Headers.ETag!.Tag);
    }

    [Fact]
    public async Task BrowserSignsInWithTheMainDevicesCodeOnceAndNeverReceivesAToken()
    {
        var clock = new WebClock();
        using var factory = Factory(clock);
        using var owner = factory.CreateClient();
        var session = await ApiTestClient.SetupOwnerAsync(owner);
        using var codeRequest = ApiTestClient.Authorized(HttpMethod.Post, "/api/v1/auth/pairings", session.Token);
        using var codeResponse = await ApiTestClient.SendAsync(owner, codeRequest);
        codeResponse.EnsureSuccessStatusCode();
        var code = await ApiTestClient.ReadAsync<PairingCodeResponse>(codeResponse);
        using var browser = Browser(factory);
        var cookies = new CookieJar();

        // Only the app's own scripts may redeem a code.
        using (var forged = await browser.PostAsJsonAsync("/api/v1/web/pair",
            new RedeemPairingCodeRequest(code.Code, "Forged"), ApiTestClient.JsonOptions))
            Assert.Equal(HttpStatusCode.Forbidden, forged.StatusCode);

        using (var paired = await cookies.SendAsync(browser, Web(HttpMethod.Post, "/api/v1/web/pair", "device",
            new RedeemPairingCodeRequest(code.Code, "Firefox on Linux"))))
        {
            Assert.Equal(HttpStatusCode.NoContent, paired.StatusCode);
            Assert.Empty(await paired.Content.ReadAsStringAsync());
            AssertProtected(CookieJar.Header(paired, "aurelia_device"));
        }
        using (var picker = await cookies.SendAsync(browser, Web(HttpMethod.Get, "/api/v1/profiles", "device")))
            Assert.Equal(HttpStatusCode.OK, picker.StatusCode);

        var other = new CookieJar();
        using (var replay = await other.SendAsync(browser, Web(HttpMethod.Post, "/api/v1/web/pair", "device",
            new RedeemPairingCodeRequest(code.Code, "Replay"))))
        {
            Assert.Equal(HttpStatusCode.Unauthorized, replay.StatusCode);
            Assert.False(other.Has("aurelia_device"));
        }
    }

    [Fact]
    public async Task BrowserSignsInWithAnApprovedCodeAndNeverReceivesAToken()
    {
        var clock = new WebClock();
        using var factory = Factory(clock);
        using var owner = factory.CreateClient();
        var session = await ApiTestClient.SetupOwnerAsync(owner);
        using var browser = Browser(factory);
        var cookies = new CookieJar();

        using var started = await cookies.SendAsync(browser, Web(HttpMethod.Post, "/api/v1/web/pairing", "device",
            new DeviceAuthorizationStartRequest("Safari on Mac")));
        started.EnsureSuccessStatusCode();
        var startBody = await started.Content.ReadAsStringAsync();
        Assert.DoesNotContain("secret", startBody, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("token", startBody, StringComparison.OrdinalIgnoreCase);
        var pairing = await ApiTestClient.ReadAsync<WebPairingResponse>(started);
        Assert.Equal(8, pairing.Code.Length);
        var pairingCookie = CookieJar.Header(started, "aurelia_pairing");
        AssertProtected(pairingCookie);
        Assert.Contains("path=/api/v1/web/pairing", pairingCookie, StringComparison.OrdinalIgnoreCase);

        using (var pending = await cookies.SendAsync(browser, Web(HttpMethod.Post, "/api/v1/web/pairing/status", "device")))
        {
            Assert.Equal(DeviceAuthorizationState.Pending, (await ApiTestClient.ReadAsync<WebPairingStatusResponse>(pending)).State);
            Assert.False(cookies.Has("aurelia_device"));
        }

        using (var lookup = ApiTestClient.Authorized(HttpMethod.Post, "/api/v1/server/device-pairings/lookup", session.Token,
            new DeviceAuthorizationLookupRequest(pairing.Code)))
        using (var found = await owner.SendAsync(lookup))
        {
            found.EnsureSuccessStatusCode();
            var preview = await ApiTestClient.ReadAsync<DeviceAuthorizationPreview>(found);
            Assert.Equal("Safari on Mac", preview.DeviceName);
            using var approve = ApiTestClient.Authorized(HttpMethod.Post, $"/api/v1/server/device-pairings/{preview.Id}/approve", session.Token);
            using var approved = await ApiTestClient.SendAsync(owner, approve);
            approved.EnsureSuccessStatusCode();
        }

        clock.Advance(TimeSpan.FromSeconds(5));
        using (var done = await cookies.SendAsync(browser, Web(HttpMethod.Post, "/api/v1/web/pairing/status", "device")))
        {
            done.EnsureSuccessStatusCode();
            Assert.DoesNotContain("token", await done.Content.ReadAsStringAsync(), StringComparison.OrdinalIgnoreCase);
            Assert.Equal(DeviceAuthorizationState.Approved, (await ApiTestClient.ReadAsync<WebPairingStatusResponse>(done)).State);
            var device = CookieJar.Header(done, "aurelia_device");
            AssertProtected(device);
            Assert.Contains("expires=", device, StringComparison.OrdinalIgnoreCase);
            Assert.True(CookieJar.Deleted(done, "aurelia_pairing"));
        }
        using (var scope = factory.Services.CreateScope())
        {
            var stored = await scope.ServiceProvider.GetRequiredService<AureliaDbContext>().DeviceAuthorizationRequests.SingleAsync();
            Assert.NotNull(stored.AcknowledgedAt);
            Assert.Null(stored.ProtectedAuthentication);
        }

        // The device cookie counts only when the request names it.
        using (var picker = await cookies.SendAsync(browser, Web(HttpMethod.Get, "/api/v1/profiles", "device")))
            Assert.Equal(HttpStatusCode.OK, picker.StatusCode);
        using (var unnamed = await cookies.SendAsync(browser, new HttpRequestMessage(HttpMethod.Get, "/api/v1/profiles")))
            Assert.Equal(HttpStatusCode.Unauthorized, unnamed.StatusCode);

        using (var wrongPin = await cookies.SendAsync(browser, Web(HttpMethod.Post, $"/api/v1/web/profiles/{session.User.Id}/unlock", "device",
            new UnlockProfileRequest("9999"))))
        {
            Assert.Equal(HttpStatusCode.Unauthorized, wrongPin.StatusCode);
            Assert.False(cookies.Has("aurelia_profile"));
        }
        using (var unlocked = await cookies.SendAsync(browser, Web(HttpMethod.Post, $"/api/v1/web/profiles/{session.User.Id}/unlock", "device",
            new UnlockProfileRequest(ApiTestClient.TestPin))))
        {
            unlocked.EnsureSuccessStatusCode();
            Assert.DoesNotContain("token", await unlocked.Content.ReadAsStringAsync(), StringComparison.OrdinalIgnoreCase);
            Assert.Equal("lucas", (await ApiTestClient.ReadAsync<WebProfileResponse>(unlocked)).User.Username);
            var profile = CookieJar.Header(unlocked, "aurelia_profile");
            AssertProtected(profile);
            Assert.DoesNotContain("expires=", profile, StringComparison.OrdinalIgnoreCase); // Ends with the browser.
        }

        using (var home = await cookies.SendAsync(browser, Web(HttpMethod.Get, "/api/v1/home", "profile")))
            Assert.Equal(HttpStatusCode.OK, home.StatusCode);
        using (var unnamed = await cookies.SendAsync(browser, new HttpRequestMessage(HttpMethod.Get, "/api/v1/home")))
            Assert.Equal(HttpStatusCode.Unauthorized, unnamed.StatusCode);
        using (var asDevice = await cookies.SendAsync(browser, Web(HttpMethod.Get, "/api/v1/home", "device")))
            Assert.Equal(HttpStatusCode.Forbidden, asDevice.StatusCode);

        var stale = cookies.Snapshot();
        using (var signedOut = await cookies.SendAsync(browser, Web(HttpMethod.Post, "/api/v1/web/sign-out", "device")))
        {
            Assert.Equal(HttpStatusCode.NoContent, signedOut.StatusCode);
            Assert.True(CookieJar.Deleted(signedOut, "aurelia_device"));
            Assert.True(CookieJar.Deleted(signedOut, "aurelia_profile"));
        }
        // Copies of the old cookies no longer work anywhere.
        using (var picker = await stale.SendAsync(browser, Web(HttpMethod.Get, "/api/v1/profiles", "device")))
            Assert.Equal(HttpStatusCode.Unauthorized, picker.StatusCode);
        using (var home = await stale.SendAsync(browser, Web(HttpMethod.Get, "/api/v1/home", "profile")))
            Assert.Equal(HttpStatusCode.Unauthorized, home.StatusCode);
    }

    [Fact]
    public async Task ADeclinedCodeLeavesNoCredentialAndWebCallsNeedTheAppHeader()
    {
        var clock = new WebClock();
        using var factory = Factory(clock);
        using var owner = factory.CreateClient();
        var session = await ApiTestClient.SetupOwnerAsync(owner);
        using var browser = Browser(factory);
        var cookies = new CookieJar();

        // A form or script on another site cannot add the header, so nothing starts.
        using (var forged = await browser.PostAsJsonAsync("/api/v1/web/pairing", new DeviceAuthorizationStartRequest("Forged"), ApiTestClient.JsonOptions))
        {
            Assert.Equal(HttpStatusCode.Forbidden, forged.StatusCode);
            Assert.Equal("web_header_required", (await ApiTestClient.ReadAsync<ApiProblem>(forged)).Code);
        }

        using var started = await cookies.SendAsync(browser, Web(HttpMethod.Post, "/api/v1/web/pairing", "device",
            new DeviceAuthorizationStartRequest("Chrome on Windows")));
        var pairing = await ApiTestClient.ReadAsync<WebPairingResponse>(started);
        using (var lookup = ApiTestClient.Authorized(HttpMethod.Post, "/api/v1/server/device-pairings/lookup", session.Token,
            new DeviceAuthorizationLookupRequest(pairing.Code)))
        using (var found = await owner.SendAsync(lookup))
        {
            var preview = await ApiTestClient.ReadAsync<DeviceAuthorizationPreview>(found);
            using var deny = ApiTestClient.Authorized(HttpMethod.Post, $"/api/v1/server/device-pairings/{preview.Id}/deny", session.Token);
            using var denied = await ApiTestClient.SendAsync(owner, deny);
            denied.EnsureSuccessStatusCode();
        }
        using var status = await cookies.SendAsync(browser, Web(HttpMethod.Post, "/api/v1/web/pairing/status", "device"));
        Assert.Equal(DeviceAuthorizationState.Denied, (await ApiTestClient.ReadAsync<WebPairingStatusResponse>(status)).State);
        Assert.True(CookieJar.Deleted(status, "aurelia_pairing"));
        Assert.False(cookies.Has("aurelia_device"));
        using (var again = await cookies.SendAsync(browser, Web(HttpMethod.Post, "/api/v1/web/pairing/status", "device")))
            Assert.Equal(HttpStatusCode.NotFound, again.StatusCode);
    }

    [Fact]
    public async Task VideoAndImageRequestsUseTheProfileCookieButOtherCallsNeedTheHeader()
    {
        var root = Path.Combine(TestPaths.CreateDataDirectory(), "Web Playback");
        Directory.CreateDirectory(root);
        var path = Path.Combine(root, "Synthetic Movie.mp4");
        var content = Enumerable.Range(0, 8192).Select(index => (byte)(index % 251)).ToArray();
        await File.WriteAllBytesAsync(path, content);
        try
        {
            var clock = new WebClock();
            using var factory = Factory(clock);
            using var owner = factory.CreateClient();
            var session = await ApiTestClient.SetupOwnerAsync(owner);
            var mediaId = await AddMovieAsync(factory, root, path);
            using var browser = Browser(factory);
            var cookies = await SignInAsync(factory, owner, session, browser, clock);

            using (var unnamed = await cookies.SendAsync(browser, new HttpRequestMessage(HttpMethod.Post, $"/api/v1/media/{mediaId}/playback")))
                Assert.Equal(HttpStatusCode.Unauthorized, unnamed.StatusCode);
            using var created = await cookies.SendAsync(browser, Web(HttpMethod.Post, $"/api/v1/media/{mediaId}/playback", "profile"));
            created.EnsureSuccessStatusCode();
            var playback = await ApiTestClient.ReadAsync<PlaybackSourceResponse>(created);

            // A <video> element sends only the cookie, with byte ranges.
            var range = new HttpRequestMessage(HttpMethod.Get, playback.StreamPath);
            range.Headers.Range = new RangeHeaderValue(100, 199);
            using (var partial = await cookies.SendAsync(browser, range))
            {
                Assert.Equal(HttpStatusCode.PartialContent, partial.StatusCode);
                Assert.Equal(content[100..200], await partial.Content.ReadAsByteArrayAsync());
            }
            using (var anonymous = await browser.GetAsync(playback.StreamPath))
                Assert.Equal(HttpStatusCode.Unauthorized, anonymous.StatusCode);
            // The live player's fetch counts as a stream read too; the invented bytes are no video.
            using (var live = await cookies.SendAsync(browser, new HttpRequestMessage(HttpMethod.Get, playback.StreamPath + "/live")))
                Assert.NotEqual(HttpStatusCode.Unauthorized, live.StatusCode);
            // An <img> element: an unknown picture is missing, not a sign-in failure.
            using (var image = await cookies.SendAsync(browser, new HttpRequestMessage(HttpMethod.Get, $"/api/v1/artwork/{Guid.NewGuid()}")))
                Assert.Equal(HttpStatusCode.NotFound, image.StatusCode);
            // The media editor shows its artwork and image drafts in <img> elements as well.
            using (var editorImage = await cookies.SendAsync(browser, new HttpRequestMessage(HttpMethod.Get, $"/api/v1/media/{mediaId}/editor/artwork/{Guid.NewGuid()}")))
                Assert.Equal(HttpStatusCode.NotFound, editorImage.StatusCode);
            using (var draft = await cookies.SendAsync(browser, new HttpRequestMessage(HttpMethod.Get, $"/api/v1/media/{mediaId}/editor/uploads/{Guid.NewGuid()}")))
                Assert.NotEqual(HttpStatusCode.Unauthorized, draft.StatusCode);
            using (var discard = await cookies.SendAsync(browser, new HttpRequestMessage(HttpMethod.Delete, $"/api/v1/media/{mediaId}/editor/uploads/{Guid.NewGuid()}")))
                Assert.Equal(HttpStatusCode.Unauthorized, discard.StatusCode);
            // Changing data with only the cookie is refused.
            var save = new HttpRequestMessage(HttpMethod.Put, $"/api/v1/media/{mediaId}/progress")
            {
                Content = JsonContent.Create(new UpdatePlaybackProgressRequest(1000, 10_000, false), options: ApiTestClient.JsonOptions),
            };
            using (var refused = await cookies.SendAsync(browser, save))
                Assert.Equal(HttpStatusCode.Unauthorized, refused.StatusCode);

            using (var ended = await cookies.SendAsync(browser, Web(HttpMethod.Post, "/api/v1/web/profile/end", "profile")))
            {
                Assert.Equal(HttpStatusCode.NoContent, ended.StatusCode);
                Assert.True(CookieJar.Deleted(ended, "aurelia_profile"));
            }
            // Without a profile the device cookie alone opens no stream.
            using (var live = await cookies.SendAsync(browser, new HttpRequestMessage(HttpMethod.Get, playback.StreamPath + "/live")))
                Assert.Equal(HttpStatusCode.Unauthorized, live.StatusCode);
            // The device stays signed in and shows the profiles again.
            using (var picker = await cookies.SendAsync(browser, Web(HttpMethod.Get, "/api/v1/profiles", "device")))
                Assert.Equal(HttpStatusCode.OK, picker.StatusCode);
        }
        finally
        {
            Directory.Delete(Path.GetDirectoryName(root)!, recursive: true);
        }
    }

    [Fact]
    public async Task ServesTheAppPagesWithTheirOwnStrictPolicyAndLeavesApiAddressesAlone()
    {
        using var factory = new AureliaServerFactory();
        using var client = factory.CreateClient();
        foreach (var address in new[] { "/", "/movies", "/title/0b7f6c4e-8f3a-4b52-9c1d-2a6e1f0d9b3c" })
        {
            using var page = await client.GetAsync(address);
            Assert.Equal(HttpStatusCode.OK, page.StatusCode);
            Assert.Equal("text/html", page.Content.Headers.ContentType?.MediaType);
            var policy = Assert.Single(page.Headers.GetValues("Content-Security-Policy"));
            Assert.Contains("script-src 'self'", policy, StringComparison.Ordinal);
            Assert.Contains("frame-ancestors 'none'", policy, StringComparison.Ordinal);
            Assert.DoesNotContain("unsafe", policy, StringComparison.Ordinal);
            Assert.True(page.Headers.CacheControl?.NoCache);
            Assert.Contains("/js/app.js", await page.Content.ReadAsStringAsync(), StringComparison.Ordinal);
        }

        using var script = await client.GetAsync("/web/js/app.js");
        Assert.Equal(HttpStatusCode.OK, script.StatusCode);
        Assert.Equal("text/javascript", script.Content.Headers.ContentType?.MediaType);
        var tag = script.Headers.ETag!;
        using (var conditional = new HttpRequestMessage(HttpMethod.Get, "/web/js/app.js"))
        {
            conditional.Headers.IfNoneMatch.Add(tag);
            using var unchanged = await client.SendAsync(conditional);
            Assert.Equal(HttpStatusCode.NotModified, unchanged.StatusCode);
        }
        foreach (var asset in new[] { "/web/app.css", "/web/js/api.js", "/web/js/logic.js", "/web/js/dom.js", "/web/js/player.js", "/web/js/live.js", "/web/js/live-logic.js", "/web/js/settings.js", "/web/icon.svg", "/web/manifest.webmanifest" })
        {
            using var response = await client.GetAsync(asset);
            Assert.True(response.StatusCode == HttpStatusCode.OK, asset);
        }
        using (var missing = await client.GetAsync("/web/missing.js"))
            Assert.Equal(HttpStatusCode.NotFound, missing.StatusCode);
        using (var head = new HttpRequestMessage(HttpMethod.Head, "/"))
        using (var headResponse = await client.SendAsync(head))
        {
            Assert.Equal(HttpStatusCode.OK, headResponse.StatusCode);
            Assert.Empty(await headResponse.Content.ReadAsByteArrayAsync());
        }

        // API addresses keep their behavior: an empty 404 and the API's own policy.
        using (var unknown = await client.GetAsync("/api/v1/does-not-exist"))
        {
            Assert.Equal(HttpStatusCode.NotFound, unknown.StatusCode);
            Assert.Empty(await unknown.Content.ReadAsByteArrayAsync());
        }
        using var info = await client.GetAsync("/api/v1/server/info");
        Assert.Equal("default-src 'none'; frame-ancestors 'none'", Assert.Single(info.Headers.GetValues("Content-Security-Policy")));
    }

    [Fact]
    public async Task HomeScreenAssetsArePublicAndCacheableButCatalogAndManagementStayPrivate()
    {
        using var factory = new AureliaServerFactory();
        using var client = factory.CreateClient();
        using var manifest = await client.GetAsync("/web/manifest.webmanifest");
        Assert.Equal(HttpStatusCode.OK, manifest.StatusCode);
        Assert.Equal("application/manifest+json", manifest.Content.Headers.ContentType?.MediaType);
        using var document = System.Text.Json.JsonDocument.Parse(await manifest.Content.ReadAsStringAsync());
        var root = document.RootElement;
        Assert.Equal("Aurelia", root.GetProperty("name").GetString());
        Assert.Equal("/", root.GetProperty("id").GetString());
        Assert.Equal("/", root.GetProperty("start_url").GetString());
        Assert.Equal("/", root.GetProperty("scope").GetString());
        Assert.Equal("standalone", root.GetProperty("display").GetString());
        var icons = root.GetProperty("icons").EnumerateArray().ToArray();
        foreach (var size in new[] { 192, 512 })
        {
            var icon = Assert.Single(icons, value => value.GetProperty("sizes").GetString() == $"{size}x{size}");
            Assert.Equal($"/web/icons/icon-{size}.png", icon.GetProperty("src").GetString());
            Assert.Equal("image/png", icon.GetProperty("type").GetString());
            Assert.Equal("any maskable", icon.GetProperty("purpose").GetString());
        }
        foreach (var size in new[] { 180, 192, 512 })
        {
            var path = $"/web/icons/icon-{size}.png";
            using var image = await client.GetAsync(path);
            Assert.Equal(HttpStatusCode.OK, image.StatusCode);
            Assert.Equal("image/png", image.Content.Headers.ContentType?.MediaType);
            var bytes = await image.Content.ReadAsByteArrayAsync();
            Assert.Equal(new byte[] { 137, 80, 78, 71, 13, 10, 26, 10 }, bytes[..8]);
            Assert.Equal(size, System.Buffers.Binary.BinaryPrimitives.ReadInt32BigEndian(bytes.AsSpan(16, 4)));
            Assert.Equal(size, System.Buffers.Binary.BinaryPrimitives.ReadInt32BigEndian(bytes.AsSpan(20, 4)));
            using var conditional = new HttpRequestMessage(HttpMethod.Get, path);
            conditional.Headers.IfNoneMatch.Add(image.Headers.ETag!);
            using var unchanged = await client.SendAsync(conditional);
            Assert.Equal(HttpStatusCode.NotModified, unchanged.StatusCode);
            using var head = new HttpRequestMessage(HttpMethod.Head, path);
            using var headResponse = await client.SendAsync(head);
            Assert.Equal(HttpStatusCode.OK, headResponse.StatusCode);
            Assert.Equal(bytes.Length, headResponse.Content.Headers.ContentLength);
            Assert.Empty(await headResponse.Content.ReadAsByteArrayAsync());
        }
        var page = await client.GetStringAsync("/");
        Assert.Contains("apple-touch-icon", page, StringComparison.Ordinal);
        Assert.Contains("/web/icons/icon-180.png", page, StringComparison.Ordinal);
        Assert.Contains("apple-mobile-web-app-capable", page, StringComparison.Ordinal);
        foreach (var path in new[] { "/api/v1/catalog/items", "/api/v1/server/status" })
        {
            using var response = await client.GetAsync(path);
            Assert.Equal(HttpStatusCode.Unauthorized, response.StatusCode);
        }
        using var worker = await client.GetAsync("/web/service-worker.js");
        Assert.Equal(HttpStatusCode.NotFound, worker.StatusCode);
    }

    private static void AssertProtected(string cookie)
    {
        Assert.Contains("httponly", cookie, StringComparison.OrdinalIgnoreCase);
        Assert.Contains("secure", cookie, StringComparison.OrdinalIgnoreCase);
        Assert.Contains("samesite=strict", cookie, StringComparison.OrdinalIgnoreCase);
    }

    private static async Task<CookieJar> SignInAsync(AureliaServerFactory factory, HttpClient owner, AuthenticationResponse session, HttpClient browser, WebClock clock)
    {
        var cookies = new CookieJar();
        using var started = await cookies.SendAsync(browser, Web(HttpMethod.Post, "/api/v1/web/pairing", "device", new DeviceAuthorizationStartRequest("Safari on iPhone")));
        var pairing = await ApiTestClient.ReadAsync<WebPairingResponse>(started);
        using (var lookup = ApiTestClient.Authorized(HttpMethod.Post, "/api/v1/server/device-pairings/lookup", session.Token, new DeviceAuthorizationLookupRequest(pairing.Code)))
        using (var found = await owner.SendAsync(lookup))
        {
            var preview = await ApiTestClient.ReadAsync<DeviceAuthorizationPreview>(found);
            using var approve = ApiTestClient.Authorized(HttpMethod.Post, $"/api/v1/server/device-pairings/{preview.Id}/approve", session.Token);
            using var approved = await ApiTestClient.SendAsync(owner, approve);
            approved.EnsureSuccessStatusCode();
        }
        clock.Advance(TimeSpan.FromSeconds(5));
        using (var status = await cookies.SendAsync(browser, Web(HttpMethod.Post, "/api/v1/web/pairing/status", "device")))
            status.EnsureSuccessStatusCode();
        using (var unlocked = await cookies.SendAsync(browser, Web(HttpMethod.Post, $"/api/v1/web/profiles/{session.User.Id}/unlock", "device",
            new UnlockProfileRequest(ApiTestClient.TestPin))))
            unlocked.EnsureSuccessStatusCode();
        return cookies;
    }

    private static async Task<Guid> AddMovieAsync(AureliaServerFactory factory, string root, string path)
    {
        using var scope = factory.Services.CreateScope();
        var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
        var now = DateTimeOffset.UtcNow;
        var library = new LibraryRoot
        {
            Id = Guid.NewGuid(),
            Name = "Web Library",
            Path = root,
            NormalizedPath = MediaPath.Normalize(root),
            Kind = LibraryKind.Movies,
            Availability = LibraryAvailability.Available,
            CreatedAt = now,
        };
        var media = new MediaItem
        {
            Id = Guid.NewGuid(),
            LibraryRoot = library,
            LibraryRootId = library.Id,
            Kind = MediaKind.Movie,
            SourcePath = path,
            NormalizedSourcePath = MediaPath.Normalize(path),
            DetectedTitle = "Synthetic Movie",
            Category = string.Empty,
            Extension = ".mp4",
            FileSize = new FileInfo(path).Length,
            FileModifiedAt = new DateTimeOffset(File.GetLastWriteTimeUtc(path), TimeSpan.Zero),
            Availability = MediaAvailability.Available,
            CreatedAt = now,
            UpdatedAt = now,
        };
        database.MediaItems.Add(media);
        await database.SaveChangesAsync();
        return media.Id;
    }

    private static AureliaServerFactory Factory(WebClock clock) => new(configureServices: services =>
    {
        services.RemoveAll<TimeProvider>();
        services.AddSingleton<TimeProvider>(clock);
    });

    /// <summary>A browser on the server's HTTPS address; cookies are kept by <see cref="CookieJar"/>.</summary>
    private static HttpClient Browser(AureliaServerFactory factory) => factory.CreateClient(new WebApplicationFactoryClientOptions
    {
        BaseAddress = new Uri("https://localhost"),
        HandleCookies = false,
        AllowAutoRedirect = false,
    });

    private static HttpRequestMessage Web(HttpMethod method, string path, string purpose, object? body = null)
    {
        var request = new HttpRequestMessage(method, path);
        request.Headers.Add("X-Aurelia-Web", purpose);
        if (body is not null) request.Content = JsonContent.Create(body, body.GetType(), options: ApiTestClient.JsonOptions);
        return request;
    }

    /// <summary>Keeps cookies like a browser, so the tests can also read each Set-Cookie header.</summary>
    private sealed class CookieJar
    {
        private readonly Dictionary<string, string> values = new(StringComparer.Ordinal);

        public bool Has(string name) => values.ContainsKey(name);

        public CookieJar Snapshot()
        {
            var copy = new CookieJar();
            foreach (var (name, value) in values) copy.values[name] = value;
            return copy;
        }

        public async Task<HttpResponseMessage> SendAsync(HttpClient client, HttpRequestMessage request)
        {
            if (values.Count > 0) request.Headers.Add("Cookie", string.Join("; ", values.Select(pair => $"{pair.Key}={pair.Value}")));
            var response = await client.SendAsync(request);
            if (response.Headers.TryGetValues("Set-Cookie", out var cookies))
                foreach (var cookie in cookies)
                {
                    var pair = cookie.Split(';')[0];
                    var separator = pair.IndexOf('=', StringComparison.Ordinal);
                    var name = pair[..separator];
                    var value = pair[(separator + 1)..];
                    if (value.Length == 0 || cookie.Contains("expires=Thu, 01 Jan 1970", StringComparison.OrdinalIgnoreCase)) values.Remove(name);
                    else values[name] = value;
                }
            return response;
        }

        public static string Header(HttpResponseMessage response, string name) =>
            Assert.Single(response.Headers.GetValues("Set-Cookie"), cookie => cookie.StartsWith(name + "=", StringComparison.Ordinal));

        public static bool Deleted(HttpResponseMessage response, string name) =>
            response.Headers.TryGetValues("Set-Cookie", out var cookies)
            && cookies.Any(cookie => cookie.StartsWith(name + "=;", StringComparison.Ordinal)
                && cookie.Contains("expires=Thu, 01 Jan 1970", StringComparison.OrdinalIgnoreCase));
    }

    private sealed class WebClock : TimeProvider
    {
        private long ticks = DateTimeOffset.UtcNow.UtcTicks;
        public override DateTimeOffset GetUtcNow() => new(Interlocked.Read(ref ticks), TimeSpan.Zero);
        public void Advance(TimeSpan interval) => Interlocked.Add(ref ticks, interval.Ticks);
    }
}
