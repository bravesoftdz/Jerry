unit Regulator;

{
  Okynko regulatoru jednoho hnaciho vozidla
}

interface

uses
  Windows, Messages, SysUtils, Variants, Classes, Graphics, Controls, Forms,
  Dialogs, StdCtrls, ComCtrls, ExtCtrls, Generics.Collections, HVDb,
  CloseTabSheet;

const
  _TIMEOUT_SEC = 5;
  _MAX_FORM_FUNC = 27;

type
  TLogCommand = record
    time:TDateTime;
  end;

  TF_DigiReg = class(TForm)
    RG_Smer: TRadioGroup;
    B_PrevzitLoko: TButton;
    B_STOP: TButton;
    CHB_Total: TCheckBox;
    L_stupen: TLabel;
    B_Idle: TButton;
    S_Status: TShape;
    T_Speed: TTimer;
    TB_reg: TTrackBar;
    L_speed: TLabel;
    CHB_Multitrack: TCheckBox;
    Label2: TLabel;
    PC_Funkce: TPageControl;
    TS_func_0_13: TTabSheet;
    TS_func_14_28: TTabSheet;
    procedure CHB_svetlaClick(Sender: TObject);
    procedure B_PrevzitLokoClick(Sender: TObject);
    procedure B_STOPClick(Sender: TObject);
    procedure RG_SmerClick(Sender: TObject);
    procedure B_IdleClick(Sender: TObject);
    procedure S_StatusMouseUp(Sender: TObject; Button: TMouseButton;
      Shift: TShiftState; X, Y: Integer);
    procedure T_SpeedTimer(Sender: TObject);
    procedure FormShow(Sender: TObject);
    procedure CHB_TotalClick(Sender: TObject);
  private

   sent:TQueue<TLogCommand>;                                                    // vytupni fronta odeslanych prikazu na server
   speed:Integer;                                                               // posledni poslana rychlost, pouziva se pri aktualizaci rychlosti v T_Speed
   HV:THV;                                                                      // hnaciho vozidlo, ktere ridim
   updating:boolean;                                                            // je true, pokud se nastavuji elementy zvnejsi
   TS:TCloseTabSheet;                                                           // odkaz na zalozku PageControlleru
   CHB_funkce:array[0.._MAX_FORM_FUNC] of TCheckBox;                            // CheckBoxy funkci
   com_err:string;                                                              // posledni komunikacni chyba

   procedure SendCmd(cmd:string);                                               // odesli prikaz konkretniho hnaciho vozidla na server
   procedure SetElementsState(state:boolean);                                   // nastav Enabled elementu na formulari na hodnotu \state
   procedure UpdateSent();                                                      // kontroluje, jestli server odpovedel na vsechny pozadavky a v priapde potreby je posila znovu
   function GetMultitrack():boolean;                                            // je okynko v multitrakci?

   procedure CreateCHBFunkce();                                                 // vytvori CheckBoxy funkci
   procedure DestroyCHBFunkce();                                                // znici CHeckBoxy funkci

  public
   addr:Word;                                                                   // adresa rizeneho HV (hnaciho vozidla)


   constructor Create(Addr:word; lok_data:string; multitrack:boolean; total:boolean; tab:TCloseTabSheet); reintroduce;
   destructor Destroy(); override;

   procedure Parse(data:TStrings);                                              // parse dat pro tento regulator
   function MyKeyPress(key:Integer):boolean;                                    // keyPress
   procedure UpdateRych(multitrack:boolean = true);                             // aktualizace rychlosti z vedjesiho regulatoru pri multitrakci

    property multitrack:boolean read GetMultitrack;                             // jestli je HV v multitrakci
  end;

////////////////////////////////////////////////////////////////////////////////

implementation

{$R *.dfm}

uses TCPClientPanel, ORList, Main, RegCollector, RPConst;

////////////////////////////////////////////////////////////////////////////////
// Vytvoreni noveho regulatoru

constructor TF_DigiReg.Create(Addr:word; lok_data:string; multitrack:boolean; total:boolean; tab:TCloseTabSheet);
begin
 inherited Create(nil);

 Self.updating := true;

 Self.addr := Addr;
 Self.TS   := tab;

 Self.sent  := TQueue<TLogCommand>.Create();
 Self.speed := -2;
 Self.CHB_Multitrack.Checked := multitrack;
 Self.CHB_Total.Checked := total;

 Self.HV := THV.Create(lok_data);

 Self.CreateCHBFunkce();

 Self.Parent := tab;
 Self.Show();
 Self.updating := false;
end;//ctor

////////////////////////////////////////////////////////////////////////////////
// Odstraneni regulatoru

destructor TF_DigiReg.Destroy();
begin
 Self.SendCmd('RELEASE;');
 Self.sent.Free();
 Self.HV.Free();
 Self.DestroyCHBFunkce();

 inherited;
end;//dtor

////////////////////////////////////////////////////////////////////////////////
// Zobrazeni okynko regulatoru

procedure TF_DigiReg.FormShow(Sender: TObject);
var i:Integer;
begin
  Self.PC_Funkce.ActivePageIndex := 0;

  Self.S_Status.Brush.Color := clGreen;
  Self.TS.Caption           := Self.HV.Nazev+' ('+Self.HV.Oznaceni+') : '+IntToStr(Self.HV.Adresa)+'      ';
  Self.L_stupen.Caption     := IntToStr(Self.HV.rychlost_stupne)+' / 28';
  Self.L_speed.Caption      := IntToStr(Self.HV.rychlost_kmph);

  Self.updating := true;
  Self.RG_Smer.ItemIndex := Self.HV.smer;
  Self.speed             := Self.HV.rychlost_stupne;
  Self.TB_reg.Position   := Self.HV.rychlost_stupne;

  for i := 0 to _MAX_FORM_FUNC do
    Self.CHB_funkce[i].Checked := Self.HV.funkce[i];

  Self.updating := false;

  Self.SetElementsState(true);

  Self.TB_reg.Enabled  := Self.CHB_Total.Checked;
  Self.RG_Smer.Enabled := Self.CHB_Total.Checked;
  Self.B_Idle.Enabled  := Self.CHB_Total.Checked;

  // zobrazeni nazvu funkci
  for i := 0 to _MAX_FORM_FUNC do
   begin
    Self.CHB_funkce[i].ShowHint := (Self.HV.funcVyznam[i] <> '');
    if (Self.HV.funcVyznam[i] <> '') then
     begin
      Self.CHB_funkce[i].Caption := 'F'+IntToStr(i) + ': ' + Self.HV.funcVyznam[i];
      Self.CHB_funkce[i].Hint    := Self.CHB_funkce[i].Caption;
     end else
      Self.CHB_funkce[i].Caption := 'F'+IntToStr(i);
   end;

  Self.B_PrevzitLoko.Enabled := false;
end;

////////////////////////////////////////////////////////////////////////////////
// Zapnuti/vypnuti totalniho rucniho rizeni

procedure TF_DigiReg.CHB_TotalClick(Sender: TObject);
begin
 if (Self.updating) then Exit(); 

 if (Self.CHB_Total.Checked) then
  begin
   Self.SendCmd('TOTAL;1');
  end else
   Self.SendCmd('TOTAL;0');
end;

////////////////////////////////////////////////////////////////////////////////
// Zapnuti/vypnuti libovolne funkce

procedure TF_DigiReg.CHB_svetlaClick(Sender: TObject);
 begin
  if (Self.updating) then Exit();
  
  if ((Sender as TCheckBox).Checked) then
    Self.SendCmd('F;'+IntToStr((Sender as TCheckBox).Tag)+';1')
  else
    Self.SendCmd('F;'+IntToStr((Sender as TCheckBox).Tag)+';0');
 end;//procedure

////////////////////////////////////////////////////////////////////////////////
// Prevzit loko do rucniho rizeni

procedure TF_DigiReg.B_PrevzitLokoClick(Sender: TObject);
begin
 PanelTCPClient.SendLn('-;LOK;'+IntToStr(Self.addr)+';PLEASE;');
end;//procedure

////////////////////////////////////////////////////////////////////////////////
// Nastavit rychlost loko na 0 stupnu

procedure TF_DigiReg.B_IdleClick(Sender: TObject);
begin
 Self.TB_reg.Position := 0;
 Self.T_SpeedTimer(Self);
end;

////////////////////////////////////////////////////////////////////////////////
// Nouzove zastaveni loko

procedure TF_DigiReg.B_STOPClick(Sender: TObject);
 begin
  Self.SendCmd('STOP');

  Self.speed := 0;
  Self.TB_reg.Position := 0;
 end;//procedure

////////////////////////////////////////////////////////////////////////////////
// Zmena smeru loko

procedure TF_DigiReg.RG_SmerClick(Sender: TObject);
 begin
  if ((Self.speed > -2) and (not Self.updating)) then
   begin
    Self.speed := -1;
    Self.T_SpeedTimer(Self);
   end;
 end;//procedure

////////////////////////////////////////////////////////////////////////////////
// Parsign dat ze serveru

procedure TF_DIgiReg.Parse(data:TStrings);
var func:TStrings;
    left, right, i:Integer;
    pom:boolean;
begin
 if (data[3] = 'F') then begin
   func := TStringList.Create();
   ExtractStringsEx(['-'], [], data[4], func);
   left := StrToInt(func[0]);
   if (data.Count > 1) then
    right := StrToInt(func[1])
   else
    right := left;
   func.Free();

   Self.updating := true;
   for i := left to right do
    if (i < _MAX_FORM_FUNC) then
     begin
      if (data[5][i-left+1] = '1') then
        Self.CHB_funkce[i].Checked := true
       else
        Self.CHB_funkce[i].Checked := false;
     end;
  Self.updating := false;

 //////////////////////////////////////////////////
 end else if (data[3] = 'SPD') then begin
  Self.updating := true;
  Self.RG_Smer.ItemIndex := StrToInt(data[6]);
  Self.speed            := StrToInt(data[5]);
  Self.TB_reg.Position  := Self.speed;
  Self.L_speed.Caption  := data[4];
  Self.L_stupen.Caption := data[5] + ' / 28';
  Self.updating := false;

  pom := not Self.TB_reg.Enabled;
  Self.B_STOP.Enabled  := true;

  if ((pom) and (Self.TB_reg.Enabled)) then Self.TB_reg.SetFocus();

 //////////////////////////////////////////////////
 end else if (data[3] = 'RESP') then begin
  if (data[4] = 'ok') then
   begin
    Self.S_Status.Brush.Color := clGreen;
    Self.com_err := '';
    if (data.Count > 5) then
       Self.L_speed.Caption := data[5];
   end else begin
    Self.S_Status.Brush.Color := clRed;
    if (data.Count > 5) then
      Self.com_err := data[5]
    else
      Self.com_err := 'loko NEKOMUNIKUJE';
   end;

  if (Self.sent.Count > 0) then Self.sent.Dequeue();

 //////////////////////////////////////////////////
 end else if (data[3] = 'AUTH') then begin
   if ((data[4] = 'ok') or (data[4] = 'total')) then
    begin
     updating := true;
     Self.CHB_Total.Checked := (data[4] = 'total');
     Self.TB_reg.Enabled  := Self.CHB_Total.Checked;
     Self.RG_Smer.Enabled := Self.CHB_Total.Checked;
     Self.B_idle.Enabled  := Self.CHB_Total.Checked;
     updating := false;

     Self.HV.ParseData(data[5]);
     Self.OnShow(Self);
    end else begin
     Self.SetElementsState(false);
     if (data[4] = 'stolen') then
      begin
       Self.S_Status.Brush.Color := clYellow;
      end else begin
       Self.S_Status.Brush.Color := clRed;
      end;
     Self.B_PrevzitLoko.Enabled := true;
    end;

   F_Main.PC_Main.Repaint();

 end else if (data[3] = 'TOTAL') then begin
   if (Self.sent.Count > 0) then
     Self.sent.Dequeue();     // TOTAL je odpovedi na TOTAL a RESP neni odesilano

   updating := true;
   Self.CHB_Total.Checked := (data[4] = '1');
   Self.TB_reg.Enabled  := Self.CHB_Total.Checked;
   Self.RG_Smer.Enabled := Self.CHB_Total.Checked;
   Self.B_Idle.Enabled  := Self.CHB_Total.Checked;
   updating := false;

   if ((F_Main.PC_Main.ActivePage = (Self.Parent as TCloseTabSheet)) and (Self.TB_reg.Enabled)) then Self.TB_reg.SetFocus();
 end;
end;//procedure

////////////////////////////////////////////////////////////////////////////////
// Kliknuti na Share S_Status zpusobi zadost o prevzeti hnaciho vozidla,
//  pokud neni HV prevzato (tj. shape je zluty)

procedure TF_DigiReg.S_StatusMouseUp(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
begin
 if (Self.com_err <> '') then
   Application.MessageBox(PChar('Loko nekomunikuje:'+#13#10+Self.com_err), 'Loko nekomunikuje', MB_OK OR MB_ICONWARNING)
 else
   if (Self.B_PrevzitLoko.Enabled) then Self.B_PrevzitLokoClick(self);
end;

////////////////////////////////////////////////////////////////////////////////
// T_Speed odesila pri kazdem ticku aktualni rychlost hnaciho vozidla
//  na server, pokud se tato rychlost zmenila od posledni rychlosti.
// Pri pohybu posuvnikem tak neni rychlost poslana rovnou, ale az pri ticku
//  timeru. To je dobre k tomu, abychom server moc nezatezovali. Pri vhodne
//  zvolene periode timeru neni rozdil od primeho posilani patrny.

procedure TF_DigiReg.T_SpeedTimer(Sender: TObject);
begin
 if (Self.B_PrevzitLoko.Enabled) then Exit();

 Self.UpdateRych();
 Self.UpdateSent();
end;//procedure

procedure TF_DigiReg.UpdateSent();
begin
 if (Self.sent.Count > 0) then
  begin
   if (Self.sent.Peek.time + EncodeTime(0, 0, _TIMEOUT_SEC, 0) < Now) then
    begin
     // timeout
     Self.sent.Dequeue();
     Self.S_Status.Brush.Color := clRed;
     Self.com_err := 'loko NEKOMUNIKUJE';
    end;
  end;
end;//procedure

procedure TF_DigiReg.UpdateRych(multitrack:boolean = true);
begin
 if ((Self.speed <> Self.TB_reg.Position) and (Self.speed > -2)) then
  begin
   Self.SendCmd('SPD-S;'+IntToStr(Self.TB_reg.Position)+';'+IntToStr(Self.RG_Smer.ItemIndex));
   Self.L_stupen.Caption := IntToStr(TB_Reg.Position)+' / 28';
   Self.speed := Self.TB_reg.Position;
   if (multitrack) then RegColl.UpdateMultitrack(Self.Parent as TCloseTabSheet);
  end;
end;//procedure

////////////////////////////////////////////////////////////////////////////////
// vyvola se, pokud je me okynko aktivni a je nad nim stiskla klavesa
//  (resi se AppcationEvent)

function TF_DigiReg.MyKeyPress(key:Integer):boolean;
begin
 if (Self.B_PrevzitLoko.Enabled) then
  begin
   if ((key = VK_RETURN) and (Self.ActiveControl <> Self.B_PrevzitLoko)) then begin
    Self.B_PrevzitLokoClick(Self);
    Exit(true);
   end;
   Exit(false);
  end;

 Result := true;

 case (key) of
  VK_NUMPAD0..VK_NUMPAD9 : Self.CHB_funkce[key-VK_NUMPAD0].Checked := not Self.CHB_funkce[key-VK_NUMPAD0].Checked;
  VK_F1..VK_F24 : Self.CHB_funkce[key-VK_F1+1].Checked := not Self.CHB_funkce[key-VK_F1+1].Checked;

  VK_ADD      : if (Self.RG_Smer.Enabled) then Self.RG_Smer.ItemIndex := 0;
  VK_SUBTRACT : if (Self.RG_Smer.Enabled) then Self.RG_Smer.ItemIndex := 1;

  83: if (Self.TB_reg.Enabled) then Self.B_STOPClick(Self);   // 's'
  73: if (Self.TB_reg.Enabled) then Self.B_IdleClick(Self);   // 'i'
 else
   Result := false;
 end;
end;//procedure

////////////////////////////////////////////////////////////////////////////////
// Odeslani prikazu serveru

procedure TF_DigiReg.SendCmd(cmd:string);
var lc:TLogCommand;
begin
 PanelTCPClient.SendLn('-;LOK;'+IntToStr(Self.addr)+';'+cmd);

 lc.time := Now;
 Self.sent.Enqueue(lc);
end;//procedure

////////////////////////////////////////////////////////////////////////////////
// Zmena enabled objektu na formulari

procedure TF_DigiReg.SetElementsState(state:boolean);
var i:Integer;
begin
  TB_reg.Enabled  := state;
  RG_Smer.Enabled := state;
  B_STOP.Enabled  := state;
  B_idle.Enabled  := state;

  for i := 0 to _MAX_FORM_FUNC do
    Self.CHB_funkce[i].Enabled := state;

  CHB_Total.Enabled := state;
  CHB_Multitrack.Enabled := state;
end;//procedure

////////////////////////////////////////////////////////////////////////////////

function TF_DigiReg.GetMultitrack():boolean;
begin
 Result := Self.CHB_Multitrack.Checked;
end;//function

////////////////////////////////////////////////////////////////////////////////
// Vytvoreni vsech CHB_funkce

procedure TF_DigiReg.CreateCHBFunkce();
var i:Integer;
    myTop:Integer;
begin
 myTop := 0;

 for i := 0 to 27 do
  begin
   if ((i mod 7) = 0) then myTop := 0;

   Self.CHB_funkce[i] := TCheckBox.Create(Self);
   with (Self.CHB_funkce[i]) do
    begin
     if (i < 14) then
       Parent  := Self.TS_func_0_13
     else
       Parent  := Self.TS_func_14_28;

     Left     := ((i div 7) mod 2)*(Self.TS_func_0_13.ClientWidth div 2);
     Top      := myTop;
     Caption  := 'F'+IntToStr(i);
     Tag      := i;
     AutoSize := false;
     Width    := (Self.TS_func_0_13.ClientWidth div 2)-10;

     Inc(myTop, 16);

     OnClick := Self.CHB_svetlaClick;
    end;//with
  end;//for i

end;

////////////////////////////////////////////////////////////////////////////////
// Zniceni vsech CHB_funkce

procedure TF_DigiReg.DestroyCHBFunkce();
var i:Integer;
begin
 for i := 0 to _MAX_FORM_FUNC do
   Self.CHB_funkce[i].Free();
end;

////////////////////////////////////////////////////////////////////////////////

end.//unit
