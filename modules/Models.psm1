<#
    Models.psm1 - typed row objects for WPF DataGrid binding.

    PSCustomObject two-way binding into a DataGrid is unreliable, so the grid
    rows are real .NET classes implementing INotifyPropertyChanged.
#>

if (-not ('WinDeploy.DriverItem' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;

namespace WinDeploy
{
    public class NotifyBase : INotifyPropertyChanged
    {
        public event PropertyChangedEventHandler PropertyChanged;
        protected void Raise(string name)
        {
            var h = PropertyChanged;
            if (h != null) h(this, new PropertyChangedEventArgs(name));
        }
    }

    public class DriverItem : NotifyBase
    {
        private bool _selected;
        public bool Selected
        {
            get { return _selected; }
            set { if (_selected != value) { _selected = value; Raise("Selected"); } }
        }

        public string OemInf { get; set; }          // oem12.inf - the DriverStore name
        public string OriginalName { get; set; }    // nvlddmkm.inf - the vendor name
        public string Provider { get; set; }
        public string ClassName { get; set; }
        public string Version { get; set; }
        public string DriverDate { get; set; }
        public string SignerName { get; set; }
        public string Devices { get; set; }         // friendly names this driver is bound to
        public long SizeBytes { get; set; }

        public string Display
        {
            get { return Provider + " " + ClassName + " " + Version; }
        }
    }

    public class DiskItem : NotifyBase
    {
        public int DiskNumber { get; set; }
        public string FriendlyName { get; set; }
        public string BusType { get; set; }
        public string PartitionStyle { get; set; }
        public long SizeBytes { get; set; }
        public long LargestFreeBytes { get; set; }
        public bool IsSystemDisk { get; set; }      // holds the currently running Windows
        public bool IsRemovable { get; set; }
        public string Volumes { get; set; }

        public string SizeGB
        {
            get { return Math.Round(SizeBytes / 1073741824.0, 1) + " GB"; }
        }
        public string FreeGB
        {
            get { return Math.Round(LargestFreeBytes / 1073741824.0, 1) + " GB"; }
        }
        public string Safety
        {
            get { return IsSystemDisk ? "SYSTEM - shrink only" : "ok"; }
        }
    }

    public class PartitionItem : NotifyBase
    {
        public int DiskNumber { get; set; }
        public int PartitionNumber { get; set; }
        public string DriveLetter { get; set; }
        public string Label { get; set; }
        public string FileSystem { get; set; }
        public long SizeBytes { get; set; }
        public long FreeBytes { get; set; }
        public bool IsSystemVolume { get; set; }
        public string Type { get; set; }

        public string SizeGB { get { return Math.Round(SizeBytes / 1073741824.0, 1) + " GB"; } }
        public string FreeGB { get { return Math.Round(FreeBytes / 1073741824.0, 1) + " GB"; } }
    }

    public class ImageItem
    {
        public int Index { get; set; }
        public string Name { get; set; }
        public string Description { get; set; }
        public string Version { get; set; }
        public string Architecture { get; set; }
        public long SizeBytes { get; set; }

        public string Display
        {
            get { return Index + ". " + Name + "  (" + Architecture + ", " +
                         Math.Round(SizeBytes / 1073741824.0, 1) + " GB)"; }
        }
    }

    public class BootEntryItem
    {
        public string Id { get; set; }
        public string Description { get; set; }
        public string Device { get; set; }
        public string Path { get; set; }
        public bool IsCurrent { get; set; }
    }
}
'@
}

Export-ModuleMember
