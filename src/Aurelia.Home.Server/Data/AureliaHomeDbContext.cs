using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Storage.ValueConversion;

namespace Aurelia.Home.Server.Data;

public sealed class AureliaHomeDbContext(DbContextOptions<AureliaHomeDbContext> options)
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

    public DbSet<PlaybackTicket> PlaybackTickets => Set<PlaybackTicket>();

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
    }
}
