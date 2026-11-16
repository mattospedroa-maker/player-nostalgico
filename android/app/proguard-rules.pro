# yt-dlp embarcado (youtubedl-android): a biblioteca não traz regras próprias e o R8 do release
# renomeava/apagava classes usadas por reflexão (Jackson, Kotlin), quebrando o yt-dlp ("gw").
-keep class com.yausername.** { *; }
-keep class com.fasterxml.jackson.** { *; }
-keep class org.apache.commons.** { *; }
-keepattributes Signature,*Annotation*,InnerClasses,EnclosingMethod
-dontwarn com.fasterxml.jackson.**
-dontwarn org.apache.commons.**
-dontwarn java.beans.**
-dontwarn org.w3c.dom.bootstrap.**
