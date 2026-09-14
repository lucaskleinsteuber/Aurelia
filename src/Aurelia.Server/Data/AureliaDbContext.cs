using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Storage.ValueConversion;

namespace Aurelia.Server.Data;

public sealed class AureliaDbContext(DbContextOptions<AureliaDbContext> options)
    : DbContext(options)
{
    public DbSet<ServerUser> Users => Set<ServerUser>();

    public DbSet<DeviceSession> DeviceSessions => Set<DeviceSession>();

    public DbSet<PairingCode> PairingCodes => Set<PairingCode>();

    public DbSet<ServerIdentity> ServerIdentities => Set<ServerIdentity>();

    public DbSet<LibraryRoot> LibraryRoots => Set<LibraryRoot>();

    public DbSet<MediaItem> MediaItems => Set<MediaItem>();

    public DbSet<LibraryScan> LibraryScans => Set<LibraryScan>();

    public DbSet<LibraryScanIssue> LibraryScanIssues => Set<LibraryScanIssue>();

    public DbSet<LibraryDiscovery> LibraryDiscoveries => Set<LibraryDiscovery>();

    public DbSet<PlaybackTicket> PlaybackTickets => Set<PlaybackTicket>();

    public DbSet<PlaybackProgress> PlaybackProgress => Set<PlaybackProgress>();

    public DbSet<MediaMetadata> MediaMetadata => Set<MediaMetadata>();
    public DbSet<MediaCredit> MediaCredits => Set<MediaCredit>();
    public DbSet<ArtworkAsset> ArtworkAssets => Set<ArtworkAsset>();
    public DbSet<MetadataReview> MetadataReviews => Set<MetadataReview>();
    public DbSet<MetadataJob> MetadataJobs => Set<MetadataJob>();
    public DbSet<UserFavorite> UserFavorites => Set<UserFavorite>();
    public DbSet<MediaCollectionRecord> MediaCollections => Set<MediaCollectionRecord>();
    public DbSet<MediaCollectionMember> MediaCollectionMembers => Set<MediaCollectionMember>();

    protected override void OnModelCreating(ModelBuilder modelBuilder)
    {
        var dateTimeOffsetConverter = new ValueConverter<DateTimeOffset, long>(
            value => value.ToUnixTimeMilliseconds(),
            value => DateTimeOffset.FromUnixTimeMilliseconds(value));
        var nullableDateTimeOffsetConverter = new ValueConverter<DateTimeOffset?, long?>(
            value => value.HasValue ? value.Value.ToUnixTimeMilliseconds() : null,
            value => value.HasValue ? DateTimeOffset.FromUnixTimeMilliseconds(value.Value) : null);

        modelBuilder.Entity<ServerUser>(entity =>
        {
            entity.HasKey(user => user.Id);
            entity.Property(user => user.Username).HasMaxLength(64).IsRequired();
            entity.Property(user => user.NormalizedUsername).HasMaxLength(64).IsRequired();
            entity.Property(user => user.PasswordHash).HasMaxLength(512).IsRequired();
            entity.Property(user => user.Role).HasConversion<string>().HasMaxLength(16);
            entity.Property(user => user.CreatedAt).HasConversion(dateTimeOffsetConverter);
            entity.HasIndex(user => user.NormalizedUsername).IsUnique();
        });

        modelBuilder.Entity<DeviceSession>(entity =>
        {
            entity.HasKey(session => session.Id);
            entity.Property(session => session.DeviceName).HasMaxLength(128).IsRequired();
            entity.Property(session => session.TokenHash).HasMaxLength(64).IsRequired();
            entity.Property(session => session.CreatedAt).HasConversion(dateTimeOffsetConverter);
            entity.Property(session => session.LastSeenAt).HasConversion(dateTimeOffsetConverter);
            entity.Property(session => session.ExpiresAt).HasConversion(dateTimeOffsetConverter);
            entity.Property(session => session.RevokedAt)
                .HasConversion(nullableDateTimeOffsetConverter);
            entity.HasIndex(session => session.TokenHash).IsUnique();
            entity.HasIndex(session => new { session.UserId, session.ExpiresAt });
            entity.HasOne(session => session.User)
                .WithMany(user => user.Sessions)
                .HasForeignKey(session => session.UserId)
                .OnDelete(DeleteBehavior.Cascade);
        });

        modelBuilder.Entity<PairingCode>(entity =>
        {
            entity.HasKey(code => code.Id);
            entity.Property(code => code.CodeHash).HasMaxLength(64).IsRequired();
            entity.Property(code => code.CreatedAt).HasConversion(dateTimeOffsetConverter);
            entity.Property(code => code.ExpiresAt).HasConversion(dateTimeOffsetConverter);
            entity.Property(code => code.ConsumedAt)
                .HasConversion(nullableDateTimeOffsetConverter);
            entity.HasIndex(code => code.CodeHash).IsUnique();
            entity.HasIndex(code => code.ExpiresAt);
            entity.HasOne(code => code.User)
                .WithMany(user => user.PairingCodes)
                .HasForeignKey(code => code.UserId)
                .OnDelete(DeleteBehavior.Cascade);
        });

        modelBuilder.Entity<ServerIdentity>(entity =>
        {
            entity.HasKey(identity => identity.Id);
            entity.Property(identity => identity.Id).ValueGeneratedNever();
            entity.Property(identity => identity.CreatedAt).HasConversion(dateTimeOffsetConverter);
            entity.ToTable(table =>
                table.HasCheckConstraint("CK_ServerIdentity_SingleRow", "Id = 1"));
        });

        modelBuilder.Entity<LibraryRoot>(entity =>
        {
            entity.HasKey(library => library.Id);
            entity.Property(library => library.Name).HasMaxLength(128).IsRequired();
            entity.Property(library => library.Path).HasMaxLength(4096).IsRequired();
            entity.Property(library => library.NormalizedPath).HasMaxLength(4096).IsRequired();
            entity.Property(library => library.Kind).HasConversion<string>().HasMaxLength(16);
            entity.Property(library => library.Availability).HasConversion<string>().HasMaxLength(16);
            entity.Property(library => library.CreatedAt).HasConversion(dateTimeOffsetConverter);
            entity.Property(library => library.LastScanStartedAt)
                .HasConversion(nullableDateTimeOffsetConverter);
            entity.Property(library => library.LastScanCompletedAt)
                .HasConversion(nullableDateTimeOffsetConverter);
            entity.Property(library => library.LastError).HasMaxLength(1024);
            entity.HasIndex(library => library.NormalizedPath).IsUnique();
        });

        modelBuilder.Entity<MediaItem>(entity =>
        {
            entity.HasKey(item => item.Id);
            entity.Property(item => item.Kind).HasConversion<string>().HasMaxLength(16);
            entity.Property(item => item.SourcePath).HasMaxLength(4096).IsRequired();
            entity.Property(item => item.NormalizedSourcePath).HasMaxLength(4096).IsRequired();
            entity.Property(item => item.DetectedTitle).HasMaxLength(512).IsRequired();
            entity.Property(item => item.OverrideTitle).HasMaxLength(512);
            entity.Property(item => item.Category).HasMaxLength(512).IsRequired();
            entity.Property(item => item.Extension).HasMaxLength(16);
            entity.Property(item => item.Availability).HasConversion<string>().HasMaxLength(16);
            entity.Property(item => item.FileModifiedAt)
                .HasConversion(nullableDateTimeOffsetConverter);
            entity.Property(item => item.CreatedAt).HasConversion(dateTimeOffsetConverter);
            entity.Property(item => item.UpdatedAt).HasConversion(dateTimeOffsetConverter);
            entity.HasIndex(item => new { item.LibraryRootId, item.NormalizedSourcePath })
                .IsUnique();
            entity.HasIndex(item => new
            {
                item.LibraryRootId,
                item.Kind,
                item.ParentId,
                item.SeasonNumber,
                item.EpisodeNumber,
            });
            entity.HasOne(item => item.LibraryRoot)
                .WithMany(library => library.MediaItems)
                .HasForeignKey(item => item.LibraryRootId)
                .OnDelete(DeleteBehavior.Cascade);
            entity.HasOne(item => item.Parent)
                .WithMany(item => item.Children)
                .HasForeignKey(item => item.ParentId)
                .OnDelete(DeleteBehavior.Restrict);
        });

        modelBuilder.Entity<LibraryScan>(entity =>
        {
            entity.HasKey(scan => scan.Id);
            entity.Property(scan => scan.State).HasConversion<string>().HasMaxLength(16);
            entity.Property(scan => scan.CreatedAt).HasConversion(dateTimeOffsetConverter);
            entity.Property(scan => scan.StartedAt)
                .HasConversion(nullableDateTimeOffsetConverter);
            entity.Property(scan => scan.CompletedAt)
                .HasConversion(nullableDateTimeOffsetConverter);
            entity.Property(scan => scan.Error).HasMaxLength(1024);
            entity.HasIndex(scan => new { scan.LibraryRootId, scan.CreatedAt });
            entity.HasOne(scan => scan.LibraryRoot)
                .WithMany(library => library.Scans)
                .HasForeignKey(scan => scan.LibraryRootId)
                .OnDelete(DeleteBehavior.Cascade);
        });

        modelBuilder.Entity<LibraryScanIssue>(entity =>
        {
            entity.HasKey(issue => issue.Id);
            entity.Property(issue => issue.Code).HasMaxLength(64).IsRequired();
            entity.Property(issue => issue.Message).HasMaxLength(1024).IsRequired();
            entity.Property(issue => issue.Path).HasMaxLength(4096);
            entity.HasOne(issue => issue.LibraryScan)
                .WithMany(scan => scan.Issues)
                .HasForeignKey(issue => issue.LibraryScanId)
                .OnDelete(DeleteBehavior.Cascade);
        });

        modelBuilder.Entity<LibraryDiscovery>(entity =>
        {
            entity.HasKey(discovery => discovery.Id);
            entity.Property(discovery => discovery.RelativePath).HasMaxLength(4096).IsRequired();
            entity.Property(discovery => discovery.NormalizedRelativePath).HasMaxLength(4096).IsRequired();
            entity.Property(discovery => discovery.DetectedTitle).HasMaxLength(512).IsRequired();
            entity.Property(discovery => discovery.SuggestedKind)
                .HasConversion<string>().HasMaxLength(16);
            entity.Property(discovery => discovery.Reason).HasMaxLength(128).IsRequired();
            entity.Property(discovery => discovery.Decision)
                .HasConversion<string>().HasMaxLength(16);
            entity.Property(discovery => discovery.CreatedAt).HasConversion(dateTimeOffsetConverter);
            entity.Property(discovery => discovery.UpdatedAt).HasConversion(dateTimeOffsetConverter);
            entity.HasIndex(discovery => new
            {
                discovery.LibraryRootId,
                discovery.NormalizedRelativePath,
            }).IsUnique();
            entity.HasOne(discovery => discovery.LibraryRoot)
                .WithMany(library => library.Discoveries)
                .HasForeignKey(discovery => discovery.LibraryRootId)
                .OnDelete(DeleteBehavior.Cascade);
        });

        modelBuilder.Entity<PlaybackTicket>(entity =>
        {
            entity.HasKey(ticket => ticket.Id);
            entity.Property(ticket => ticket.TokenHash).HasMaxLength(64).IsRequired();
            entity.Property(ticket => ticket.CreatedAt).HasConversion(dateTimeOffsetConverter);
            entity.Property(ticket => ticket.ExpiresAt).HasConversion(dateTimeOffsetConverter);
            entity.Property(ticket => ticket.RevokedAt)
                .HasConversion(nullableDateTimeOffsetConverter);
            entity.HasIndex(ticket => ticket.TokenHash).IsUnique();
            entity.HasIndex(ticket => new { ticket.UserId, ticket.ExpiresAt });
            entity.HasIndex(ticket => new { ticket.DeviceSessionId, ticket.ExpiresAt });
            entity.HasOne(ticket => ticket.MediaItem)
                .WithMany(item => item.PlaybackTickets)
                .HasForeignKey(ticket => ticket.MediaItemId)
                .OnDelete(DeleteBehavior.Cascade);
            entity.HasOne(ticket => ticket.DeviceSession)
                .WithMany(session => session.PlaybackTickets)
                .HasForeignKey(ticket => ticket.DeviceSessionId)
                .OnDelete(DeleteBehavior.Cascade);
            entity.HasOne(ticket => ticket.User)
                .WithMany(user => user.PlaybackTickets)
                .HasForeignKey(ticket => ticket.UserId)
                .OnDelete(DeleteBehavior.NoAction);
        });

        modelBuilder.Entity<PlaybackProgress>(entity =>
        {
            entity.HasKey(progress => progress.Id);
            entity.Property(progress => progress.LastPlayedAt)
                .HasConversion(dateTimeOffsetConverter);
            entity.Property(progress => progress.UpdatedAt)
                .HasConversion(dateTimeOffsetConverter);
            entity.HasIndex(progress => new { progress.UserId, progress.MediaItemId })
                .IsUnique();
            entity.HasOne(progress => progress.MediaItem)
                .WithMany(item => item.PlaybackProgress)
                .HasForeignKey(progress => progress.MediaItemId)
                .OnDelete(DeleteBehavior.Cascade);
            entity.HasOne(progress => progress.User)
                .WithMany(user => user.PlaybackProgress)
                .HasForeignKey(progress => progress.UserId)
                .OnDelete(DeleteBehavior.Cascade);
        });

        modelBuilder.Entity<MediaMetadata>(entity =>
        {
            entity.HasKey(metadata => metadata.MediaItemId);
            entity.Property(metadata => metadata.Provider).HasMaxLength(32);
            entity.Property(metadata => metadata.ProviderMediaId).HasMaxLength(64);
            entity.Property(metadata => metadata.ProviderMediaType).HasMaxLength(16);
            entity.Property(metadata => metadata.ProviderTitle).HasMaxLength(512);
            entity.Property(metadata => metadata.ProviderOriginalTitle).HasMaxLength(512);
            entity.Property(metadata => metadata.ProviderOverview).HasMaxLength(8192);
            entity.Property(metadata => metadata.ProviderReleaseDate).HasMaxLength(32);
            entity.Property(metadata => metadata.ProviderContentRating).HasMaxLength(32);
            entity.Property(metadata => metadata.ProviderGenresJson).HasMaxLength(4096);
            entity.Property(metadata => metadata.ProviderStudiosJson).HasMaxLength(4096);
            entity.Property(metadata => metadata.ProviderCountriesJson).HasMaxLength(4096);
            entity.Property(metadata => metadata.ManualTitle).HasMaxLength(512);
            entity.Property(metadata => metadata.ManualOriginalTitle).HasMaxLength(512);
            entity.Property(metadata => metadata.ManualOverview).HasMaxLength(8192);
            entity.Property(metadata => metadata.ManualReleaseDate).HasMaxLength(32);
            entity.Property(metadata => metadata.ManualContentRating).HasMaxLength(32);
            entity.Property(metadata => metadata.ManualGenresJson).HasMaxLength(4096);
            entity.Property(metadata => metadata.ManualStudiosJson).HasMaxLength(4096);
            entity.Property(metadata => metadata.ManualCountriesJson).HasMaxLength(4096);
            entity.Property(metadata => metadata.ReviewState).HasConversion<string>().HasMaxLength(16);
            entity.Property(metadata => metadata.ProviderUpdatedAt).HasConversion(nullableDateTimeOffsetConverter);
            entity.Property(metadata => metadata.UpdatedAt).HasConversion(dateTimeOffsetConverter);
            entity.HasIndex(metadata => new { metadata.Provider, metadata.ProviderMediaId });
            entity.HasOne(metadata => metadata.MediaItem).WithOne(item => item.Metadata)
                .HasForeignKey<MediaMetadata>(metadata => metadata.MediaItemId)
                .OnDelete(DeleteBehavior.Cascade);
        });

        modelBuilder.Entity<MediaCredit>(entity =>
        {
            entity.HasKey(credit => credit.Id);
            entity.Property(credit => credit.ProviderPersonId).HasMaxLength(64);
            entity.Property(credit => credit.Name).HasMaxLength(256).IsRequired();
            entity.Property(credit => credit.Department).HasMaxLength(64).IsRequired();
            entity.Property(credit => credit.Job).HasMaxLength(128);
            entity.Property(credit => credit.Character).HasMaxLength(512);
            entity.Property(credit => credit.ProfilePath).HasMaxLength(512);
            entity.HasIndex(credit => new { credit.MediaItemId, credit.SortOrder });
            entity.HasOne(credit => credit.Metadata).WithMany(metadata => metadata.Credits)
                .HasForeignKey(credit => credit.MediaItemId).OnDelete(DeleteBehavior.Cascade);
        });

        modelBuilder.Entity<ArtworkAsset>(entity =>
        {
            entity.HasKey(asset => asset.Id);
            entity.Property(asset => asset.Kind).HasConversion<string>().HasMaxLength(16);
            entity.Property(asset => asset.ProviderPath).HasMaxLength(512).IsRequired();
            entity.Property(asset => asset.RelativeFilePath).HasMaxLength(512).IsRequired();
            entity.Property(asset => asset.ContentType).HasMaxLength(64).IsRequired();
            entity.Property(asset => asset.CreatedAt).HasConversion(dateTimeOffsetConverter);
            entity.HasIndex(asset => new { asset.MediaItemId, asset.Kind, asset.ProviderPath }).IsUnique();
            entity.HasIndex(asset => asset.RelativeFilePath).IsUnique();
            entity.HasOne(asset => asset.Metadata).WithMany(metadata => metadata.Artwork)
                .HasForeignKey(asset => asset.MediaItemId).OnDelete(DeleteBehavior.Cascade);
        });

        modelBuilder.Entity<MetadataReview>(entity =>
        {
            entity.HasKey(review => review.Id);
            entity.Property(review => review.Reason).HasMaxLength(256).IsRequired();
            entity.Property(review => review.CandidatesJson).HasMaxLength(32768).IsRequired();
            entity.Property(review => review.State).HasConversion<string>().HasMaxLength(16);
            entity.Property(review => review.CreatedAt).HasConversion(dateTimeOffsetConverter);
            entity.Property(review => review.UpdatedAt).HasConversion(dateTimeOffsetConverter);
            entity.HasIndex(review => review.MediaItemId).IsUnique();
            entity.HasOne(review => review.MediaItem).WithMany(item => item.MetadataReviews)
                .HasForeignKey(review => review.MediaItemId).OnDelete(DeleteBehavior.Cascade);
        });

        modelBuilder.Entity<MetadataJob>(entity =>
        {
            entity.HasKey(job => job.Id);
            entity.Property(job => job.State).HasConversion<string>().HasMaxLength(16);
            entity.Property(job => job.Error).HasMaxLength(1024);
            entity.Property(job => job.CreatedAt).HasConversion(dateTimeOffsetConverter);
            entity.Property(job => job.StartedAt).HasConversion(nullableDateTimeOffsetConverter);
            entity.Property(job => job.CompletedAt).HasConversion(nullableDateTimeOffsetConverter);
            entity.HasIndex(job => new { job.State, job.CreatedAt });
        });

        modelBuilder.Entity<UserFavorite>(entity =>
        {
            entity.HasKey(favorite => favorite.Id);
            entity.Property(favorite => favorite.CreatedAt).HasConversion(dateTimeOffsetConverter);
            entity.HasIndex(favorite => new { favorite.UserId, favorite.MediaItemId }).IsUnique();
            entity.HasOne(favorite => favorite.User).WithMany(user => user.Favorites)
                .HasForeignKey(favorite => favorite.UserId).OnDelete(DeleteBehavior.Cascade);
            entity.HasOne(favorite => favorite.MediaItem).WithMany(item => item.Favorites)
                .HasForeignKey(favorite => favorite.MediaItemId).OnDelete(DeleteBehavior.Cascade);
        });

        modelBuilder.Entity<MediaCollectionRecord>(entity =>
        {
            entity.HasKey(collection => collection.Id);
            entity.Property(collection => collection.Name).HasMaxLength(512).IsRequired();
            entity.Property(collection => collection.Provider).HasMaxLength(32);
            entity.Property(collection => collection.ProviderCollectionId).HasMaxLength(64);
            entity.Property(collection => collection.SourceKey).HasMaxLength(4096);
            entity.Property(collection => collection.CreatedAt).HasConversion(dateTimeOffsetConverter);
            entity.Property(collection => collection.UpdatedAt).HasConversion(dateTimeOffsetConverter);
            entity.HasIndex(collection => new { collection.Provider, collection.ProviderCollectionId });
            entity.HasIndex(collection => collection.SourceKey);
        });

        modelBuilder.Entity<MediaCollectionMember>(entity =>
        {
            entity.HasKey(member => new { member.CollectionId, member.MediaItemId });
            entity.HasOne(member => member.Collection).WithMany(collection => collection.Members)
                .HasForeignKey(member => member.CollectionId).OnDelete(DeleteBehavior.Cascade);
            entity.HasOne(member => member.MediaItem).WithMany(item => item.CollectionMemberships)
                .HasForeignKey(member => member.MediaItemId).OnDelete(DeleteBehavior.Cascade);
        });
    }
}
