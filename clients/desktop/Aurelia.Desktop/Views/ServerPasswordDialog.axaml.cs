using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Interactivity;

namespace Aurelia.Desktop.Views;

/// <summary>Asks for the Server Password when a management action finds management locked; null when cancelled.</summary>
public sealed partial class ServerPasswordDialog : Window
{
    public ServerPasswordDialog()
    {
        InitializeComponent();
        Opened += (_, _) => PasswordBox.Focus();
    }

    internal ServerPasswordDialog(string? problem) : this()
    {
        ProblemText.Text = problem;
        ProblemText.IsVisible = problem is not null;
    }

    private void Unlock(object? sender, RoutedEventArgs e) => Finish();

    private void Cancel(object? sender, RoutedEventArgs e) => Close(null);

    private void PasswordKeyDown(object? sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter) Finish();
        else if (e.Key == Key.Escape) Close(null);
    }

    private void Finish()
    {
        var password = PasswordBox.Text ?? "";
        PasswordBox.Text = "";
        if (password.Length > 0) Close(password);
    }
}
