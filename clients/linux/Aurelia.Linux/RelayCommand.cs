using System.Windows.Input;

namespace Aurelia.Linux;

/// <summary>A command that runs an action, for key bindings and menu items.</summary>
public sealed class RelayCommand(Action execute) : ICommand
{
    public event EventHandler? CanExecuteChanged
    {
        add { }
        remove { }
    }

    public bool CanExecute(object? parameter) => true;

    public void Execute(object? parameter) => execute();
}
