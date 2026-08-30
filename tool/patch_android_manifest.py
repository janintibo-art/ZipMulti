from pathlib import Path
import re

manifest = Path('android/app/src/main/AndroidManifest.xml')
if not manifest.exists():
    raise SystemExit('AndroidManifest.xml introuvable. Exécutez flutter create avant ce script.')

text = manifest.read_text(encoding='utf-8')
text = text.replace('android:launchMode="singleTop"', 'android:launchMode="singleTask"')

marker = '<!-- ZIPMULTI_FILE_INTENTS -->'
if marker not in text:
    filters = f'''
            {marker}
            <!-- Ouvrir un ZIP depuis le gestionnaire de fichiers Android -->
            <intent-filter>
                <action android:name="android.intent.action.VIEW" />
                <category android:name="android.intent.category.DEFAULT" />
                <data android:mimeType="application/zip" android:scheme="content" />
                <data android:mimeType="application/x-zip-compressed" android:scheme="content" />
            </intent-filter>
            <!-- Recevoir un ou plusieurs ZIP via Partager -->
            <intent-filter>
                <action android:name="android.intent.action.SEND" />
                <category android:name="android.intent.category.DEFAULT" />
                <data android:mimeType="application/zip" />
                <data android:mimeType="application/x-zip-compressed" />
            </intent-filter>
            <intent-filter>
                <action android:name="android.intent.action.SEND_MULTIPLE" />
                <category android:name="android.intent.category.DEFAULT" />
                <data android:mimeType="application/zip" />
                <data android:mimeType="application/x-zip-compressed" />
            </intent-filter>
'''
    closing = '</activity>'
    idx = text.find(closing)
    if idx == -1:
        raise SystemExit('Balise </activity> introuvable.')
    text = text[:idx] + filters + text[idx:]

manifest.write_text(text, encoding='utf-8')

# shared_preferences 2.5.x prend en charge Android à partir de l'API 24.
# Flutter génère actuellement le minSdk via flutter.minSdkVersion : on le fixe
# explicitement afin que la compilation GitHub ne dépende pas de la valeur par défaut.
kts = Path('android/app/build.gradle.kts')
groovy = Path('android/app/build.gradle')

if kts.exists():
    gradle = kts.read_text(encoding='utf-8')
    gradle = re.sub(r'(?m)^\s*minSdk\s*=\s*flutter\.minSdkVersion\s*$', '        minSdk = 24', gradle)
    kts.write_text(gradle, encoding='utf-8')
elif groovy.exists():
    gradle = groovy.read_text(encoding='utf-8')
    gradle = re.sub(r'(?m)^\s*minSdkVersion\s+flutter\.minSdkVersion\s*$', '        minSdkVersion 24', gradle)
    groovy.write_text(gradle, encoding='utf-8')

print('Android patché : ouverture/partage ZIP + minSdk 24 pour ZipMulti.')

# receive_sharing_intent exige compileSdk 37, alors que flutter create genere 36.
if kts.exists():
    gradle = kts.read_text(encoding='utf-8')
    gradle = re.sub(r'(?m)^\s*compileSdk\s*=\s*flutter\.compileSdkVersion\s*$',
                    '    compileSdk = 37', gradle)
    kts.write_text(gradle, encoding='utf-8')
    print('compileSdk force a 37.')
elif groovy.exists():
    gradle = groovy.read_text(encoding='utf-8')
    gradle = re.sub(r'(?m)^\s*compileSdkVersion\s+flutter\.compileSdkVersion\s*$',
                    '    compileSdkVersion 37', gradle)
    groovy.write_text(gradle, encoding='utf-8')
    print('compileSdk force a 37.')

# Signature de l'APK de release quand android/key.properties est present.
if kts.exists():
    g = kts.read_text(encoding='utf-8')
    if 'keystoreProperties' not in g:
        entete = (
            'import java.util.Properties\n'
            'import java.io.FileInputStream\n\n'
            'val keystorePropertiesFile = rootProject.file("key.properties")\n'
            'val keystoreProperties = Properties()\n'
            'if (keystorePropertiesFile.exists()) {\n'
            '    keystoreProperties.load(FileInputStream(keystorePropertiesFile))\n'
            '}\n\n'
        )
        g = entete + g
        bloc = (
            '    signingConfigs {\n'
            '        if (keystorePropertiesFile.exists()) {\n'
            '            create("release") {\n'
            '                keyAlias = keystoreProperties["keyAlias"] as String\n'
            '                keyPassword = keystoreProperties["keyPassword"] as String\n'
            '                storeFile = rootProject.file(keystoreProperties["storeFile"] as String)\n'
            '                storePassword = keystoreProperties["storePassword"] as String\n'
            '            }\n'
            '        }\n'
            '    }\n\n'
            '    buildTypes {\n'
        )
        g = g.replace('    buildTypes {\n', bloc, 1)
        g = g.replace(
            'signingConfig = signingConfigs.getByName("debug")',
            'signingConfig = if (keystorePropertiesFile.exists()) '
            'signingConfigs.getByName("release") else signingConfigs.getByName("debug")',
            1)
        kts.write_text(g, encoding='utf-8')
        print('Signature de release configuree.')


# ---------------------------------------------------------------------------
# Declaration des fichiers a MediaStore.
#
# ZipMulti ecrit ses volumes directement sur le disque. L'index multimedia
# d'Android ne les connait donc pas, et le raccourci « Telechargements »
# affiche un dossier vide tant qu'un gestionnaire de fichiers n'a pas parcouru
# le vrai dossier. On expose MediaScannerConnection a Dart pour les declarer
# nous-memes des qu'ils sont ecrits.
# ---------------------------------------------------------------------------
activities = list(Path('android/app/src/main/kotlin').rglob('MainActivity.kt'))
if not activities:
    raise SystemExit('MainActivity.kt introuvable.')

for activity in activities:
    source = activity.read_text(encoding='utf-8')
    if 'zipmulti/media' in source:
        continue

    package_line = ''
    for line in source.splitlines():
        if line.startswith('package '):
            package_line = line
            break
    if not package_line:
        raise SystemExit(f'Ligne package absente de {activity}.')

    activity.write_text(package_line + '''

import android.media.MediaScannerConnection
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val mediaChannel = "zipmulti/media"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, mediaChannel)
            .setMethodCallHandler { call, result ->
                if (call.method == "scan") {
                    val paths = call.argument<List<String>>("paths")
                    if (paths.isNullOrEmpty()) {
                        result.success(false)
                    } else {
                        MediaScannerConnection.scanFile(
                            applicationContext,
                            paths.toTypedArray(),
                            null,
                            null
                        )
                        result.success(true)
                    }
                } else {
                    result.notImplemented()
                }
            }
    }
}
''', encoding='utf-8')
    print(f'MainActivity enrichi : {activity}')
