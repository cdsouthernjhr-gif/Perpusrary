import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/router/routes.dart';
import '../../../shared/widgets/app_drawer.dart';

/// Reports hub.
class ReportsScreen extends StatelessWidget {
  const ReportsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    Widget tile(IconData i, String t, String s, String route, String key) => Card(
          child: ListTile(
            key: Key(key),
            leading: Icon(i),
            title: Text(t),
            subtitle: Text(s),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push(route),
          ),
        );
    return Scaffold(
      drawer: const AppDrawer(),
      appBar: AppBar(title: const Text('Laporan')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        tile(Icons.inventory_2_outlined, 'Laporan inventori', 'Status, keadaan, lokasi, kategori, nilai', Routes.inventory, 'reports.inventory'),
        tile(Icons.timeline, 'Pergerakan stok', 'Sejarah tambah, ubah status, pindah lokasi', Routes.movements, 'reports.movements'),
        tile(Icons.history, 'Log aktiviti', 'Siapa mengubah apa dan bila', Routes.activity, 'reports.activity'),
        tile(Icons.table_view, 'Eksport Excel', 'Semua laporan dalam satu fail .xlsx (8 worksheet)', Routes.exportExcel, 'reports.export'),
      ]),
    );
  }
}
