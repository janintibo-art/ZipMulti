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
