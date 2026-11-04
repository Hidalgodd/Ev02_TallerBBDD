-- Triggers de Prospecting.
-- Requiere prospecting-db.sql.

-- 3.1 Normalizar datos de empresas (igual idea que trg_validar_datos_ciente del profe)
CREATE OR REPLACE TRIGGER trg_empresas_normalizar
BEFORE INSERT OR UPDATE ON empresas
FOR EACH ROW
BEGIN
    :NEW.rut          := UPPER(TRIM(:NEW.rut));
    :NEW.razon_social := TRIM(:NEW.razon_social);
    :NEW.sitio_web    := LOWER(TRIM(:NEW.sitio_web));
END trg_empresas_normalizar;
/

-- 3.2 Normalizar datos de contactos
CREATE OR REPLACE TRIGGER trg_contactos_normalizar
BEFORE INSERT OR UPDATE ON contactos
FOR EACH ROW
BEGIN
    :NEW.nombre := INITCAP(TRIM(:NEW.nombre));
    :NEW.email  := LOWER(TRIM(:NEW.email));
END trg_contactos_normalizar;
/

--Un solo contacto principal por empresa.
CREATE OR REPLACE TRIGGER trg_contacto_principal_unico
FOR INSERT OR UPDATE OF es_principal ON contactos
COMPOUND TRIGGER

    TYPE t_principal IS RECORD (
        id_empresa  contactos.id_empresa%TYPE,
        id_contacto contactos.id_contacto%TYPE
    );
    TYPE t_lista IS TABLE OF t_principal INDEX BY PLS_INTEGER;
    g_lista t_lista;

    AFTER EACH ROW IS
        v_pos PLS_INTEGER;
    BEGIN
        IF :NEW.es_principal = 1 THEN
            v_pos := g_lista.COUNT + 1;
            g_lista(v_pos).id_empresa  := :NEW.id_empresa;
            g_lista(v_pos).id_contacto := :NEW.id_contacto;
        END IF;
    END AFTER EACH ROW;

    AFTER STATEMENT IS
    BEGIN
        FOR i IN 1 .. g_lista.COUNT LOOP
            UPDATE contactos
            SET es_principal = 0
            WHERE id_empresa = g_lista(i).id_empresa
              AND id_contacto <> g_lista(i).id_contacto
              AND es_principal = 1;
        END LOOP;
        g_lista.DELETE;
    END AFTER STATEMENT;

END trg_contacto_principal_unico;
/

-- No permitir interacciones con empresas marcadas NO_CONTACTAR
CREATE OR REPLACE TRIGGER trg_interaccion_no_contactar
BEFORE INSERT ON interacciones
FOR EACH ROW
DECLARE
    v_estado empresas.estado%TYPE;
BEGIN
    SELECT estado INTO v_estado FROM empresas WHERE id_empresa = :NEW.id_empresa;

    IF v_estado = 'NO_CONTACTAR' THEN
        RAISE_APPLICATION_ERROR(-20002, 'No se puede registrar la interaccion: la empresa esta en NO_CONTACTAR.');
    END IF;

EXCEPTION
    WHEN no_data_found THEN
        NULL;   -- empresa inexistente: que lo reclame la FK
END trg_interaccion_no_contactar;
/

-- Ajustar la probabilidad cuando la oportunidad se cierra
CREATE OR REPLACE TRIGGER trg_oportunidad_probabilidad
BEFORE INSERT OR UPDATE OF etapa ON oportunidades
FOR EACH ROW
BEGIN
    IF :NEW.etapa = 'GANADA' THEN
        :NEW.probabilidad := 100;
    ELSIF :NEW.etapa = 'PERDIDA' THEN
        :NEW.probabilidad := 0;
    END IF;
END trg_oportunidad_probabilidad;
/

-- Oportunidad GANADA -> la empresa pasa a CLIENTE
CREATE OR REPLACE TRIGGER trg_oportunidad_ganada
AFTER INSERT OR UPDATE OF etapa ON oportunidades
FOR EACH ROW
WHEN (NEW.etapa = 'GANADA')
BEGIN
    UPDATE empresas
    SET estado = 'CLIENTE'
    WHERE id_empresa = :NEW.id_empresa
      AND estado <> 'CLIENTE';
END trg_oportunidad_ganada;
/

--Auditoria de cambios de estado de la empresa
CREATE OR REPLACE TRIGGER trg_empresas_auditoria_estado
AFTER UPDATE OF estado ON empresas
FOR EACH ROW
WHEN (OLD.estado <> NEW.estado)
BEGIN
    INSERT INTO auditoria_estado_empresa (id_empresa, estado_anterior, estado_nuevo, usuario)
    VALUES (:OLD.id_empresa, :OLD.estado, :NEW.estado, USER);
END trg_empresas_auditoria_estado;
/
