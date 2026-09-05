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
    }
}
