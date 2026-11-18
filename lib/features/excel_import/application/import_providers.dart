import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/remote/supabase/supabase_providers.dart';
import 'import_jobs.dart';

final importJobRepositoryProvider =
    Provider<ImportJobRepository>((ref) => SupabaseImportJobRepository(ref.watch(supabaseClientProvider)));
