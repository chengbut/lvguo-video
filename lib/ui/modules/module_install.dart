import '../../core_bridge.dart';
import '../../local_store.dart';
import '../../models.dart';
import '../../source_modules.dart';

Future<String?> applyModuleInstall(
  AppRepository repository,
  LocalStore store,
  SourceModule module, {
  bool enable = true,
}) async {
  final id = await repository.installModule(module.token);
  if (enable && !module.installed) {
    await store.setSourceEnabled(id, true);
  }
  final site = SourceSite.byId(id);
  if (site.devices && !await repository.sourceDevices(id)) {
    try {
      if (!await repository.sourceDevices(id, register: true)) {
        throw AppFailure('设备注册未完成');
      }
    } catch (failure) {
      return '${module.name} 已安装，但$failure；下次打开应用时会再次注册';
    }
  }
  return null;
}
