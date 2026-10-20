using System;
using System.Windows;
using System.Windows.Controls;

namespace WbPet
{
    public partial class SettingsWindow : Window
    {
        private readonly PetConfig _cfg;
        private readonly Action _apply;
        private bool _loading = true;

        public SettingsWindow(PetConfig cfg, Action apply)
        {
            _cfg = cfg;
            _apply = apply;
            InitializeComponent();

            FontSlider.Value = Math.Clamp(cfg.FontSize, 10, 18);
            OpacitySlider.Value = Math.Clamp(cfg.PanelOpacity, 20, 100);
            PetSlider.Value = Math.Clamp(cfg.PetScale * 100, 40, 100);
            _loading = false;
            UpdateLabels();
        }

        private void UpdateLabels()
        {
            FontLabel.Text = $"字号：{FontSlider.Value:0}（10–18）";
            OpacityLabel.Text = $"面板不透明度：{OpacitySlider.Value:0}%";
            PetLabel.Text = $"角色大小：{PetSlider.Value:0}%（40–100）";
        }

        private void FontSlider_ValueChanged(object sender, RoutedPropertyChangedEventArgs<double> e)
        {
            if (_loading) return;
            _cfg.FontSize = Math.Round(FontSlider.Value);
            UpdateLabels();
            _apply();
        }

        private void OpacitySlider_ValueChanged(object sender, RoutedPropertyChangedEventArgs<double> e)
        {
            if (_loading) return;
            _cfg.PanelOpacity = Math.Round(OpacitySlider.Value);
            UpdateLabels();
            _apply();
        }

        private void PetSlider_ValueChanged(object sender, RoutedPropertyChangedEventArgs<double> e)
        {
            if (_loading) return;
            _cfg.PetScale = Math.Round(PetSlider.Value) / 100.0;
            UpdateLabels();
            _apply();
        }

        private void Close_Click(object sender, RoutedEventArgs e) => Close();
    }
}
