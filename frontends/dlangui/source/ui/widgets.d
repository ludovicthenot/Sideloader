/++
    Petits constructeurs de widgets partages par les ecrans.

    Le but est que les frames decrivent la structure de la page et pas la
    mise en forme : tout ce qui est couleur / espacement / taille vit dans
    resources/res/theme_sideloader.xml, reference ici par son style id.
+/
module ui.widgets;

import dlangui;

/// Intitule de section, au-dessus d'un groupe de champs.
TextWidget caption(dstring text) {
    auto w = new TextWidget(null, text);
    w.styleId = "SL_CAPTION";
    return w;
}

/// Libelle d'un champ (colonne de gauche d'une table).
TextWidget fieldLabel(dstring text) {
    auto w = new TextWidget(null, text);
    w.styleId = "SL_LABEL";
    return w;
}

/// Valeur en lecture seule. Volontairement un TextWidget et pas un EditLine
/// desactive : un champ de saisie grise se lit comme une panne, pas comme
/// une information.
TextWidget fieldValue(string id = null, dstring text = ""d) {
    auto w = new TextWidget(id, text);
    w.styleId = "SL_VALUE";
    w.layoutWidth = FILL_PARENT;
    return w;
}

/// Message occupant tout le cadre quand il n'y a rien a montrer.
/// MultilineTextWidget et pas TextWidget : ce dernier est mono-ligne et
/// rend les \n en glyphe manquant.
TextWidget emptyState(string id, dstring text) {
    auto w = new MultilineTextWidget(id, text);
    w.styleId = "SL_EMPTY";
    w.layoutWidth = FILL_PARENT;
    w.layoutHeight = FILL_PARENT;
    return w;
}

/// Paragraphe sur plusieurs lignes. A reserver aux conteneurs dont la
/// largeur est connue a la mesure : dans une fenetre auto-dimensionnee,
/// dlangui mesure une ligne puis en dessine plusieurs, et ca se chevauche.
/// Dans ce cas, empiler des `bodyText` a la place.
TextWidget paragraph(dstring text) {
    auto w = new MultilineTextWidget(null, text);
    w.styleId = "SL_PARAGRAPH";
    w.layoutWidth = FILL_PARENT;
    return w;
}

/// Une ligne de texte courant.
TextWidget bodyText(dstring text) {
    auto w = new TextWidget(null, text);
    w.styleId = "SL_BODY";
    w.layoutWidth = FILL_PARENT;
    return w;
}

/// Texte d'aide discret.
TextWidget hint(dstring text) {
    auto w = new TextWidget(null, text);
    w.styleId = "SL_HINT";
    w.layoutWidth = FILL_PARENT;
    return w;
}

/// Message d'erreur, masque par defaut.
TextWidget errorText(string id) {
    auto w = new TextWidget(id, ""d);
    w.styleId = "SL_ERROR";
    w.layoutWidth = FILL_PARENT;
    w.visibility = Visibility.Gone;
    return w;
}

/// Filet horizontal de 1px.
Widget separator() {
    auto w = new Widget();
    w.styleId = "SL_SEPARATOR";
    w.layoutWidth = FILL_PARENT;
    w.layoutHeight = 1;
    return w;
}

/// Table de deux colonnes libelle / valeur.
TableLayout fieldTable(string id = null) {
    auto t = new TableLayout(id);
    t.colCount = 2;
    t.layoutWidth = FILL_PARENT;
    t.layoutHeight = WRAP_CONTENT;
    return t;
}

/// Ajoute une ligne libelle / valeur et renvoie le widget de valeur.
TextWidget addField(TableLayout table, dstring label, string valueId = null) {
    table.addChild(fieldLabel(label));
    auto v = fieldValue(valueId);
    table.addChild(v);
    return v;
}

/// Action principale de l'ecran. Un seul bouton accentue par vue.
Button primaryButton(Action action) {
    auto b = new Button(action);
    b.styleId = "BUTTON_PRIMARY";
    return b;
}

/// ditto
Button primaryButton(string id, dstring text) {
    auto b = new Button(id, text);
    b.styleId = "BUTTON_PRIMARY";
    return b;
}
